#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import AppKit

let textView = ComposerTextView()

func send(_ character: String, modifiers: NSEvent.ModifierFlags = .command) {
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: 0
    )!
    precondition(textView.performKeyEquivalent(with: event), "Shortcut \(modifiers.rawValue)+\(character) was not handled")
}

textView.string = "hola mundo"
textView.setSelectedRange(NSRange(location: 10, length: 0))
send("a")
precondition(textView.selectedRange() == NSRange(location: 0, length: 10), "⌘A did not select all")

send("c")
precondition(NSPasteboard.general.string(forType: .string) == "hola mundo", "⌘C did not copy")

send("x")
precondition(textView.string.isEmpty, "⌘X did not cut")

send("v")
precondition(textView.string == "hola mundo", "⌘V did not paste")

send("z")
send("z", modifiers: [.command, .shift])
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoard/ComposerTextView.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/board-editing-shortcuts"

"$work_dir/board-editing-shortcuts"
