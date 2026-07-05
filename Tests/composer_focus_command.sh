#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
composer.string = "texto existente"
composer.setSelectedRange(NSRange(location: 0, length: 0))

let panel = FloatingPanel(
    contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.contentView = composer

focusComposer(panel: panel, composer: composer)

precondition(panel.isVisible, "The focus command did not show the panel")
precondition(panel.firstResponder === composer, "The composer did not become first responder")
precondition(
    composer.selectedRange() == NSRange(location: composer.string.utf16.count, length: 0),
    "The caret did not move to the end of the existing draft"
)
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoard/ComposerFocus.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/composer-focus-command"

"$work_dir/composer-focus-command"
