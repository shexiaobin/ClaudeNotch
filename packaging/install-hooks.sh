#!/bin/bash
# 安装 ClaudeNotch.app 并配置 Claude Code / Cursor / Codex hooks。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

resolve_source_app() {
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

SOURCE_APP="$(resolve_source_app)"
if [[ -z "$SOURCE_APP" ]]; then
  osascript -e 'display dialog "未找到 ClaudeNotch.app：请把 ClaudeNotch.app 与本脚本放在同一文件夹，或先把 ClaudeNotch.app 拖到「应用程序」文件夹。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
  echo "错误：找不到 ClaudeNotch.app"
  exit 1
fi

TARGET_APP="/Applications/ClaudeNotch.app"
APP="$TARGET_APP"

if [[ "$SOURCE_APP" != "$TARGET_APP" ]]; then
  echo "正在安装 ClaudeNotch.app → $TARGET_APP"
  if ! ditto "$SOURCE_APP" "$TARGET_APP"; then
    APP="$SOURCE_APP"
    osascript -e 'display dialog "无法复制到「应用程序」文件夹，将临时使用当前 ClaudeNotch.app 路径。\n\n如果当前路径来自 DMG，卸载 DMG 后 hooks 会失效。建议手动把 ClaudeNotch.app 拖到「应用程序」后重新运行本脚本。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
    echo "警告：无法复制到 $TARGET_APP，改用 $APP"
  fi
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

hooks = cfg.setdefault("hooks", {})
managed_names = {
    "claude_permission_bridge.py",
    "claude_notification_bridge.py",
    "claude_stop_bridge.py",
}

def merge_hook(event, entry):
    existing = hooks.get(event, [])
    if not isinstance(existing, list):
        existing = []
    kept = []
    for item in existing:
        nested = item.get("hooks") if isinstance(item, dict) else None
        commands = [
            h.get("command")
            for h in nested
            if isinstance(h, dict) and isinstance(h.get("command"), str)
        ] if isinstance(nested, list) else []
        if any(any(command.endswith("/" + name) for name in managed_names) for command in commands):
            continue
        kept.append(item)
    kept.append(entry)
    hooks[event] = kept

merge_hook("PermissionRequest", {"matcher": ".*", "hooks": [
    {"type": "command", "command": f"{bridge}/claude_permission_bridge.py"}
]})
merge_hook("Notification", {"matcher": "", "hooks": [
    {"type": "command", "command": f"{bridge}/claude_notification_bridge.py"}
]})
merge_hook("Stop", {"matcher": "", "hooks": [
    {"type": "command", "command": f"{bridge}/claude_stop_bridge.py"}
]})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"Claude Code hooks → {path}")
PYEOF

mkdir -p "$HOME/.cursor"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"

python3 << PYEOF
import json, os

path = "$CURSOR_HOOKS"
bridge = "$BRIDGE"

if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
else:
    cfg = {}

if not isinstance(cfg, dict):
    cfg = {}
cfg.setdefault("version", 1)
hooks = cfg.setdefault("hooks", {})

managed_names = {
    "cursor_shell_hook.py",
    "cursor_file_hook.py",
    "cursor_stop_hook.py",
}

def merge_hook(event, command):
    existing = hooks.get(event, [])
    if not isinstance(existing, list):
        existing = []
    kept = []
    for item in existing:
        item_command = item.get("command") if isinstance(item, dict) else None
        if item_command and any(item_command.endswith("/" + name) for name in managed_names):
            continue
        kept.append(item)
    kept.append({"command": command})
    hooks[event] = kept

merge_hook("beforeShellExecution", f"{bridge}/cursor_shell_hook.py")
merge_hook("afterFileEdit", f"{bridge}/cursor_file_hook.py")
merge_hook("stop", f"{bridge}/cursor_stop_hook.py")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"Cursor hooks → {path}")
PYEOF

mkdir -p "$HOME/.codex"
CODEX_HOOKS="$HOME/.codex/hooks.json"

python3 << PYEOF
import json, os

path = "$CODEX_HOOKS"
bridge = "$BRIDGE"

if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
else:
    cfg = {}

if not isinstance(cfg, dict):
    cfg = {}
hooks = cfg.setdefault("hooks", {})

managed_names = {
    "codex_permission_bridge.py",
    "codex_stop_bridge.py",
    "claude_permission_bridge.py",
    "claude_stop_bridge.py",
}

def merge_hook(event, entry):
    existing = hooks.get(event, [])
    if not isinstance(existing, list):
        existing = []
    kept = []
    for item in existing:
        nested = item.get("hooks") if isinstance(item, dict) else None
        commands = [
            h.get("command")
            for h in nested
            if isinstance(h, dict) and isinstance(h.get("command"), str)
        ] if isinstance(nested, list) else []
        if any(any(command.endswith("/" + name) for name in managed_names) for command in commands):
            continue
        kept.append(item)
    kept.append(entry)
    hooks[event] = kept

merge_hook("PermissionRequest", {"matcher": ".*", "hooks": [
    {"type": "command", "command": f"{bridge}/codex_permission_bridge.py"}
]})
merge_hook("Stop", {"hooks": [
    {"type": "command", "command": f"{bridge}/codex_stop_bridge.py"}
]})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"Codex hooks → {path}")
PYEOF

echo ""
echo "已配置 hooks。请重启 Cursor；Claude Code / Codex 下次启动时生效。"
osascript -e 'display dialog "ClaudeNotch.app 已安装并写入 Claude Code、Cursor 与 Codex hooks。\n\n请重启 Cursor；Claude Code / Codex 下次启动时生效。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
