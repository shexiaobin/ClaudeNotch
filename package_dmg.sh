#!/bin/sh
# 构建 ClaudeNotch.app 并生成可分发的 DMG（需 Xcode Command Line Tools）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${CLAUDENOTCH_VERSION:-1.0.3}"
DIST="$ROOT/dist"
STAGE="$DIST/staging"
APP_NAME="ClaudeNotch.app"
VOLNAME="ClaudeNotch ${VERSION}"

echo "=== [1/5] 编译 ==="
"$ROOT/ClaudeNotch/build.sh"

echo "=== [2/5] 组装 .app ==="
rm -rf "$STAGE"
mkdir -p "$STAGE/$APP_NAME/Contents/MacOS"
mkdir -p "$STAGE/$APP_NAME/Contents/Resources/bridge"

cp "$ROOT/ClaudeNotch/.build-local/ClaudeNotch" "$STAGE/$APP_NAME/Contents/MacOS/"
cp "$ROOT/packaging/Info.plist" "$STAGE/$APP_NAME/Contents/"

for f in "$ROOT/bridge"/*.py; do
  cp "$f" "$STAGE/$APP_NAME/Contents/Resources/bridge/"
done
chmod +x "$STAGE/$APP_NAME/Contents/Resources/bridge"/*.py

echo "=== [3/5] 安装脚本与说明 ==="
cp "$ROOT/packaging/install-hooks.sh" "$STAGE/Install Hooks.command"
chmod +x "$STAGE/Install Hooks.command"
cp "$ROOT/packaging/README_DIST.txt" "$STAGE/请先读我.txt"

echo "=== [4/5] 代码签名（本机 ad-hoc）==="
if codesign --force --deep --sign - "$STAGE/$APP_NAME" 2>/dev/null; then
  echo "codesign 完成"
else
  echo "警告：codesign 失败（可忽略，接收方可能需在「隐私与安全性」中允许运行）"
fi

DMG_PATH="$DIST/ClaudeNotch-${VERSION}-arm64.dmg"
echo "=== [5/5] 生成 DMG → $DMG_PATH ==="
rm -f "$DMG_PATH"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH"

echo ""
echo "完成: $DMG_PATH"
ls -lh "$DMG_PATH"
