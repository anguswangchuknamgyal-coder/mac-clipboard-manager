#!/bin/bash
set -euo pipefail

# 构建并打包成 ClipDrawer.app（无需 Xcode，仅用 Command Line Tools）
APP_NAME="ClipDrawer"
BUNDLE_ID="com.wangchuknamgyal.clipdrawer"
DISPLAY_NAME="拾贴"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> 编译 (release)…"
swift build -c release

BIN="$ROOT/.build/release/$APP_NAME"
APP="$ROOT/$APP_NAME.app"

echo "==> 打包 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 临时签名，避免未签名导致的运行限制
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> 完成：$APP"
