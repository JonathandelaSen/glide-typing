import AppKit

/// NSTextView normally receives editing shortcuts through an application's
/// Edit menu. GlideBoard is an accessory app with a non-activating panel, so
/// route the standard commands directly while its composer has key focus.
final class ComposerTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if key == "z", modifiers == [.command, .shift] {
            undoManager?.redo()
            return true
        }
        guard modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        case "z": undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
