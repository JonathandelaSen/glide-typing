#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Carbon
import AppKit

// Default shortcut: ⌘⌥T.
UserDefaults.standard.removeObject(forKey: "transformHotKeyCode")
UserDefaults.standard.removeObject(forKey: "transformHotKeyModifiers")
precondition(Settings.transformHotKeyCode == UInt32(kVK_ANSI_T))
precondition(Settings.transformHotKeyModifiers == UInt32(cmdKey | optionKey))

// Response cleaning: strip wrapping quotes and meta prefixes, veto refusals.
precondition(TransformCleaner.clean("\"Hola, mundo\"") == "Hola, mundo")
precondition(TransformCleaner.clean("Resultado: hola") == "hola")
precondition(TransformCleaner.clean("«Bonjour»") == "Bonjour")
precondition(TransformCleaner.clean("Línea 1\nLínea 2") == "Línea 1\nLínea 2")
precondition(TransformCleaner.clean("No puedo ayudarte con eso") == nil)
precondition(TransformCleaner.clean("   ") == nil)

// Prompts embed the text and demand a bare answer.
precondition(TransformAction.fix.prompt(for: "ola ke ase").contains("ola ke ase"))
precondition(TransformAction.translate.instructions.contains("ÚNICAMENTE"))
precondition(TransformAction.fix.maxTokens(for: "corto") >= 80)

// Clipboard restore: the paste fallback must give the user's clipboard back.
let pasteboard = NSPasteboard.general
let original = pasteboard.string(forType: .string)
pasteboard.clearContents()
pasteboard.setString("contenido original del usuario", forType: .string)
let snapshot = ClipboardSnapshot()
pasteboard.clearContents()
pasteboard.setString("texto transformado temporal", forType: .string)
snapshot.restore()
precondition(pasteboard.string(forType: .string) == "contenido original del usuario")
if let original {
    pasteboard.clearContents()
    pasteboard.setString(original, forType: .string)
}
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoard/KeyboardLayout.swift" \
    "$repo_root/Sources/GlideBoard/Settings.swift" \
    "$repo_root/Sources/GlideBoard/TransformAction.swift" \
    "$repo_root/Sources/GlideBoard/ClipboardSnapshot.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/transform-anywhere"

"$work_dir/transform-anywhere"
