#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$ROOT/bridge"

echo "=== ClaudeNotch 安装 ==="
echo ""

# 1. Build
echo "[1/4] 编译 ClaudeNotch..."
"$ROOT/ClaudeNotch/build.sh"

# 2. Make bridges executable
echo "[2/4] 设置桥接脚本权限..."
chmod +x "$BRIDGE/claude_permission_bridge.py"
chmod +x "$BRIDGE/claude_notification_bridge.py"
chmod +x "$BRIDGE/claude_stop_bridge.py"
chmod +x "$BRIDGE/cursor_shell_hook.py"
chmod +x "$BRIDGE/cursor_stop_hook.py"
chmod +x "$BRIDGE/cursor_file_hook.py"

# 3. Claude Code hooks (~/.claude/settings.json)
echo "[3/4] 配置 Claude Code hooks..."
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

# Merge hooks (preserve existing hooks the user may have)
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

print(f"  Claude Code hooks → {path}")
PYEOF

# 4. Cursor hooks (~/.cursor/hooks.json)
echo "[4/4] 配置 Cursor hooks..."
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

print(f"  Cursor hooks → {path}")
PYEOF

APP="$ROOT/ClaudeNotch/.build-local/ClaudeNotch"
echo ""
echo "=== 安装完成 ==="
echo ""
echo "启动: $APP"
echo "或:   open $APP"
echo ""
echo "支持:"
echo "  ✓ Claude Code — PermissionRequest / Notification / Stop"
echo "  ✓ Cursor      — beforeShellExecution / afterFileEdit / stop"
echo ""
echo "状态栏 ◉ 图标 → 菜单可查看历史 / 开关电子宠物"
