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
    osascript -e 'display dialog "无法复制到「应用程序」文件夹，安装未完成。\n\n请手动把 ClaudeNotch.app 拖到「应用程序」后重新运行 Install Hooks.command。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
    echo "错误：无法复制到 $TARGET_APP"
    exit 1
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

if ! command -v python3 >/dev/null 2>&1; then
  osascript -e 'display dialog "未找到 python3，无法写入 hooks。\n\n请先安装 Xcode Command Line Tools：xcode-select --install" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
  echo "错误：未找到 python3"
  exit 1
fi

python3 "$BRIDGE/install_hooks.py" repair --bridge "$BRIDGE" --no-socket-check

echo ""
echo "已配置 hooks。请重启 Cursor；Claude Code / Codex 下次启动时生效。"
osascript -e 'display dialog "ClaudeNotch.app 已安装并写入 Claude Code、Cursor 与 Codex hooks。\n\n请重启 Cursor；Claude Code / Codex 下次启动时生效。" buttons {"好"} default button 1 with title "ClaudeNotch"' 2>/dev/null || true
