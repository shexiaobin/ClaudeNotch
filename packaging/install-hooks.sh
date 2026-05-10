#!/bin/bash
# 配置 Claude Code / Cursor hooks，指向本 DMG 或「应用程序」中的 ClaudeNotch.app 内 bridge。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

resolve_app() {
  if [[ -d "$SCRIPT_DIR/ClaudeNotch.app" ]]; then
    echo "$SCRIPT_DIR/ClaudeNotch.app"
    return
  fi
  if [[ -d "/Applications/ClaudeNotch.app" ]]; then
    echo "/Applications/ClaudeNotch.app"
    return
  fi
  echo ""
}

APP="$(resolve_app)"
if [[ -z "$APP" ]]; then
  osascript -e 'display dialog "未找到 ClaudeNotch.app：请把 ClaudeNotch.app 与本脚本放在同一文件夹，或先把 ClaudeNotch.app 拖到「应用程序」文件夹。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
  echo "错误：找不到 ClaudeNotch.app"
  exit 1
fi

BRIDGE="$APP/Contents/Resources/bridge"
if [[ ! -d "$BRIDGE" ]]; then
  echo "错误：应用包内缺少 bridge：$BRIDGE"
  exit 1
fi

for f in "$BRIDGE"/*.py; do
  chmod +x "$f" 2>/dev/null || true
done

mkdir -p "$HOME/.claude"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

python3 << PYEOF
import json, os

path = "$CLAUDE_SETTINGS"
bridge = "$BRIDGE"

if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
else:
    cfg = {}

if "hooks" not in cfg:
    cfg["hooks"] = {}

cfg["hooks"]["PermissionRequest"] = [
    {"matcher": ".*", "hooks": [
        {"type": "command", "command": f"{bridge}/claude_permission_bridge.py"}
    ]}
]
cfg["hooks"]["Notification"] = [
    {"matcher": "", "hooks": [
        {"type": "command", "command": f"{bridge}/claude_notification_bridge.py"}
    ]}
]
cfg["hooks"]["Stop"] = [
    {"matcher": "", "hooks": [
        {"type": "command", "command": f"{bridge}/claude_stop_bridge.py"}
    ]}
]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"Claude Code hooks → {path}")
PYEOF

mkdir -p "$HOME/.cursor"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"

python3 << PYEOF
import json

bridge = "$BRIDGE"
cfg = {
    "version": 1,
    "hooks": {
        "beforeShellExecution": [
            {"command": f"{bridge}/cursor_shell_hook.py"}
        ],
        "afterFileEdit": [
            {"command": f"{bridge}/cursor_file_hook.py"}
        ],
        "stop": [
            {"command": f"{bridge}/cursor_stop_hook.py"}
        ]
    }
}

with open("$CURSOR_HOOKS", "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"Cursor hooks → $CURSOR_HOOKS")
PYEOF

echo ""
echo "已配置 hooks。请重启 Cursor；Claude Code 下次启动时生效。"
osascript -e 'display dialog "Hooks 已写入 Claude Code 与 Cursor 配置。\n\n请将 ClaudeNotch.app 保留在原位置或「应用程序」中（勿删除），否则 hooks 会失效。\n\n建议重启 Cursor。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
