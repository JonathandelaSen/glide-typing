#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/GlideBoard.app}"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/GlideBoard"
[[ -f "$plist" && -x "$executable" ]]

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[[ "$(read_plist CFBundleIdentifier)" == "com.jon.glideboard" ]]
[[ "$(read_plist CFBundleExecutable)" == "GlideBoard" ]]
[[ "$(read_plist CFBundleName)" == "Numa" ]]
[[ "$(read_plist CFBundleDisplayName)" == "Numa" ]]

source_version=$(sed -nE 's/.*static let code = ([0-9]+).*/\1/p' \
  Sources/GlideBoardCore/BuildVersion.swift)
[[ "$(read_plist CFBundleVersion)" == "$source_version" ]]

for theme in crystal pulse organic digital; do
  for phase in activation finish; do
    [[ -f "$app/Contents/Resources/NumaSounds/$theme-$phase.aiff" ]]
  done
done

codesign --verify --deep --strict "$app"
echo "PASS numa bundle contract"
