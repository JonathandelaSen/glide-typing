#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import AppKit

let button = CGRect(x: 50, y: 4, width: 34, height: 22)
precondition(dictationButtonWasPressed(at: CGPoint(x: 67, y: 15),
                                       buttonRect: button,
                                       helpVisible: false))
precondition(dictationButtonWasPressed(at: CGPoint(x: 47, y: 15),
                                       buttonRect: button,
                                       helpVisible: false),
             "The hit target should include the same forgiving inset as other toolbar buttons")
precondition(!dictationButtonWasPressed(at: CGPoint(x: 67, y: 15),
                                        buttonRect: button,
                                        helpVisible: true),
             "Clicks must dismiss help instead of starting the microphone")
precondition(!dictationButtonWasPressed(at: CGPoint(x: 120, y: 15),
                                        buttonRect: button,
                                        helpVisible: false))
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoard/DictationButtonHitTesting.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/dictation-button"

"$work_dir/dictation-button"
