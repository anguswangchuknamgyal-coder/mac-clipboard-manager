#!/bin/bash
set -euo pipefail

# 构建 ClipDrawer.app 并打包成可拖拽安装的 .dmg
#   产物：./dist/ClipDrawer-<VERSION>.dmg
#   用法：./make_dmg.sh [VERSION]

APP_NAME="ClipDrawer"
DISPLAY_NAME="拾贴"
VERSION="${1:-1.0.0}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 1) 编译 + 生成 .app（复用 build.sh）
./build.sh

APP="$ROOT/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "Error: $APP not found after build" >&2
    exit 1
fi

# 2) 准备临时挂载目录
DIST="$ROOT/dist"
STAGE="$ROOT/.dmg-stage"
DMG_PATH="$DIST/${APP_NAME}-${VERSION}.dmg"

rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$DIST" "$STAGE"

# 3) 把 .app 复制到 stage 并放一个 Applications 软链接（拖拽安装）
cp -R "$APP" "$STAGE/$DISPLAY_NAME.app"
ln -s /Applications "$STAGE/Applications"

# 4) 用 hdiutil 直接生成压缩 .dmg
echo "==> 打包 $DMG_PATH …"
hdiutil create \
    -volname "$DISPLAY_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGE"

# 5) 对 .dmg 也做临时签名，避免「损坏」提示
codesign --force --sign - "$DMG_PATH" >/dev/null 2>&1 || true

SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "==> 完成：$DMG_PATH ($SIZE)"
