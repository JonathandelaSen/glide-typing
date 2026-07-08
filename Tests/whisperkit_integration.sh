#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"

grep -q 'https://github.com/argmaxinc/argmax-oss-swift.git' "$repo_root/Package.swift"
grep -q '.product(name: "WhisperKit", package: "argmax-oss-swift")' "$repo_root/Package.swift"
grep -q 'NSMicrophoneUsageDescription' "$repo_root/build.sh"
grep -q 'WhisperKitDictationEngine' "$repo_root/Sources/GlideBoard/AppDelegate.swift"

swift build --package-path "$repo_root"
