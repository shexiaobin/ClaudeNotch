#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$ROOT/bridge"

echo "=== ClaudeNotch 安装 ==="
echo ""

# 1. Build
echo "[1/5] 编译 ClaudeNotch..."
"$ROOT/ClaudeNotch/build.sh"

# 2. Make bridges executable
echo "[2/5] 设置桥接脚本权限..."
chmod +x "$BRIDGE"/*.py

# 3. Claude Code hooks (~/.claude/settings.json)
echo "[3/5] 配置 Claude Code hooks..."
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

print(f"  Claude Code hooks → {path}")
PYEOF

# 4. Cursor hooks (~/.cursor/hooks.json)
echo "[4/5] 配置 Cursor hooks..."
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

# 5. Codex hooks (~/.codex/hooks.json)
echo "[5/5] 配置 Codex hooks..."
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

print(f"  Codex hooks → {path}")
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
echo "  ✓ Codex       — PermissionRequest / Stop"
echo ""
echo "状态栏 ◉ 图标 → 菜单可查看历史 / 开关电子宠物"
