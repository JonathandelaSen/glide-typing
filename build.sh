#!/bin/zsh
# Builds GlideBoard.app into ./build
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/GlideBoard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/GlideBoard "$APP/Contents/MacOS/GlideBoard"
cp Resources/en_words.txt Resources/es_words.txt "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GlideBoard</string>
    <key>CFBundleIdentifier</key><string>com.jon.glideboard</string>
    <key>CFBundleName</key><string>GlideBoard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>GlideBoard usa el micrófono para transcribir dictado localmente con WhisperKit.</string>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity if present, so the Accessibility
# permission survives rebuilds (ad-hoc signatures change on every build).
if security find-identity -v -p codesigning | grep -q "GlideBoard Signing"; then
    codesign --force --sign "GlideBoard Signing" --identifier com.jon.glideboard "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
