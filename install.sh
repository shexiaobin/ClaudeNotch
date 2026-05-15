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

# 3. Hooks (~/.claude, ~/.cursor, ~/.codex)
echo "[3/5] 配置并诊断 hooks..."
python3 "$BRIDGE/install_hooks.py" repair --bridge "$BRIDGE" --no-socket-check

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
