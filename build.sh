#!/bin/zsh
# Builds GlideBoard.app into ./build
set -e
cd "$(dirname "$0")"

# Only the app product: the checks runner (@testable) needs a debug build.
swift build -c release --product GlideBoard

APP=build/GlideBoard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/GlideBoard "$APP/Contents/MacOS/GlideBoard"
cp Resources/en_words.txt Resources/es_words.txt "$APP/Contents/Resources/"
cp -R Resources/NumaSounds "$APP/Contents/Resources/NumaSounds"

BUILD_VERSION=$(sed -nE 's/.*static let code = ([0-9]+).*/\1/p' \
  Sources/GlideBoardCore/BuildVersion.swift)
if [[ -z "$BUILD_VERSION" ]]; then
  echo "Could not read BuildVersion.code" >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GlideBoard</string>
    <key>CFBundleIdentifier</key><string>com.jon.glideboard</string>
    <key>CFBundleName</key><string>Numa</string>
    <key>CFBundleDisplayName</key><string>Numa</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Numa usa el micrófono para reconocer «Numa» y «graba audio», y para transcribir dictado localmente con WhisperKit. No guarda audio.</string>
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
