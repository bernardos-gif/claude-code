#!/bin/bash
# Assembles build/BladeRush.app: release binary, Info.plist, icon generated in code
# (BladeSim icon -> iconutil), Data + Shaders in Resources, ad-hoc code signature.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/BladeRush.app"
VERSION="${VERSION:-1.0.0}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BladeRush" "$APP/Contents/MacOS/BladeRush"
cp -R "$ROOT/Data" "$APP/Contents/Resources/Data"
mkdir -p "$APP/Contents/Resources/Shaders"
cp "$ROOT"/Sources/BladeRush/Shaders/*.metal "$APP/Contents/Resources/Shaders/"

# Icon: drawn procedurally by IconArt.swift at every iconset size.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN/BladeSim" icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Blade Rush</string>
    <key>CFBundleDisplayName</key><string>Blade Rush</string>
    <key>CFBundleIdentifier</key><string>com.bladerush.game</string>
    <key>CFBundleExecutable</key><string>BladeRush</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>GCSupportsControllerUserInteraction</key><true/>
    <key>GCSupportedGameControllers</key>
    <array><dict><key>ProfileName</key><string>ExtendedGamepad</string></dict></array>
    <key>LSEnvironment</key>
    <dict><key>BLADERUSH_USE_BUNDLE</key><string>1</string></dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Packaged $APP"
echo "Run it with: open \"$APP\""
