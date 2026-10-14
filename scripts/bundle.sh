#!/bin/sh
# Собирает build/Splitroute.app (ad-hoc подпись, Apple Developer не нужен).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIG=${CONFIG:-release}

sh scripts/fetch-sing-box.sh
swift build -c "$CONFIG" --product Splitroute
swift build -c "$CONFIG" --product splitroute-helper
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP="$ROOT/build/Splitroute.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN/Splitroute" "$BIN/splitroute-helper" "$APP/Contents/MacOS/"
cp Resources/bin/sing-box "$APP/Contents/Resources/sing-box"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Splitroute</string>
  <key>CFBundleDisplayName</key><string>Splitroute</string>
  <key>CFBundleIdentifier</key><string>com.splitroute.app</string>
  <key>CFBundleExecutable</key><string>Splitroute</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Splitroute</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/sing-box"
codesign --force --sign - "$APP/Contents/MacOS/splitroute-helper"
codesign --force --sign - "$APP"
echo "Готово: $APP"
