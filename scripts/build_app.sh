#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MemoPilot"
DIST_DIR="$PROJECT_DIR/dist"
RELEASES_DIR="$PROJECT_DIR/Releases"
ASSETS_DIR="$PROJECT_DIR/Assets"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ICON_PATH="$ASSETS_DIR/MemoPilot.icns"
ZIP_PATH="$RELEASES_DIR/$APP_NAME-macOS-arm64.zip"

cd "$PROJECT_DIR"
mkdir -p "$ASSETS_DIR" "$RELEASES_DIR" "$DIST_DIR"

if [ ! -f "$ICON_PATH" ]; then
    swift "$PROJECT_DIR/scripts/generate_icon.swift" "$ASSETS_DIR"
    mv -f "$ASSETS_DIR/AppIcon.icns" "$ICON_PATH"
    if [ -f "$ASSETS_DIR/icon-preview.png" ]; then
        mv -f "$ASSETS_DIR/icon-preview.png" "$ASSETS_DIR/MemoPilotIconMaster.png"
    fi
fi

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MemoPilot</string>
    <key>CFBundleIdentifier</key>
    <string>com.xiatianze.MemoPilot</string>
    <key>CFBundleName</key>
    <string>MemoPilot</string>
    <key>CFBundleDisplayName</key>
    <string>MemoPilot</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>MemoPilot 需要访问您的日历，以便根据您的备忘和微信截图自动创建日程及提前提醒。</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>MemoPilot 需要访问您的提醒事项，以便自动为您创建待办提醒与闹钟。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MemoPilot 需要控制「备忘录」与「终端」，以便归档整理后的关键信息及协助登录 OpenAI 账号。</string>
</dict>
</plist>
EOF

xattr -cr "$APP_BUNDLE" 2>/dev/null || true
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
touch "$APP_BUNDLE"

# 同步到 /Applications 与桌面，方便本机直接使用
rm -rf "/Applications/$APP_NAME.app" "/Users/xiatianze/Desktop/$APP_NAME.app"
ditto "$APP_BUNDLE" "/Applications/$APP_NAME.app"
ditto "$APP_BUNDLE" "/Users/xiatianze/Desktop/$APP_NAME.app"
touch "/Applications/$APP_NAME.app" "/Users/xiatianze/Desktop/$APP_NAME.app"

# 生成可直接分发安装的 Releases/MemoPilot-macOS-arm64.zip（无 __MACOSX 与 AppleDouble 垃圾文件）
rm -f "$ZIP_PATH"
COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ZIP_PATH"
if zipinfo -1 "$ZIP_PATH" | grep -E '^__MACOSX/|(^|/)\._' >/dev/null 2>&1; then
    zip -d "$ZIP_PATH" '__MACOSX/*' '*/._*' '._*' >/dev/null 2>&1 || true
fi

echo "✅ 已生成应用包：$APP_BUNDLE"
echo "✅ 已安装至系统：/Applications/$APP_NAME.app 及 /Users/xiatianze/Desktop/$APP_NAME.app"
echo "✅ 已生成安装包：$ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'))"
