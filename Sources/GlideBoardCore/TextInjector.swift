import CoreGraphics
import AppKit

/// Posts synthetic keyboard events to whatever app currently has focus.
/// Requires the Accessibility permission.
enum TextInjector {
    private static let source = CGEventSource(stateID: .combinedSessionState)

    /// Modifiers a global hotkey can carry. While any of them is still
    /// physically held, the focused app reads incoming keystrokes as
    /// shortcuts instead of text. Caps lock (`.maskAlphaShift`) stays
    /// latched between presses and must not count as "held".
    private static let hotKeyModifiers: CGEventFlags =
        [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    static func modifiersBlockTyping(_ flags: CGEventFlags) -> Bool {
        !flags.isDisjoint(with: hotKeyModifiers)
    }

    /// True while the user physically holds a hotkey-style modifier.
    static var physicalModifiersDown: Bool {
        modifiersBlockTyping(CGEventSource.flagsState(.combinedSessionState))
    }

    static func type(_ text: String) {
        let utf16 = Array(text.utf16)
        // CGEvent unicode strings are limited; send in small chunks.
        let chunkSize = 16
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + chunkSize, utf16.count)])
            post(chunk: chunk)
            i += chunkSize
        }
    }

    private static func post(chunk: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        // New events inherit the session's live modifier flags. When a hotkey
        // triggered this delivery the user's ⌘ is still down, and the target
        // would treat the text events as shortcuts and drop the characters.
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func pressKey(_ keyCode: CGKeyCode, times: Int = 1, flags: CGEventFlags = []) {
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Post shortcuts spaced out in time: apps need a beat to process each
    /// one (e.g. select-all must land before copy reads the selection).
    static func pressSequence(_ steps: [(key: CGKeyCode, flags: CGEventFlags)],
                              interval: TimeInterval = 0.09) {
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                pressKey(step.key, flags: step.flags)
            }
        }
    }

    static let backspaceKey: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36
    static let forwardDeleteKey: CGKeyCode = 117
    static let tabKey: CGKeyCode = 48
    static let escapeKey: CGKeyCode = 53
    static let leftArrowKey: CGKeyCode = 123
    static let downArrowKey: CGKeyCode = 125
    static let upArrowKey: CGKeyCode = 126
    static let rightArrowKey: CGKeyCode = 124
    static let aKey: CGKeyCode = 0
    static let cKey: CGKeyCode = 8
    static let vKey: CGKeyCode = 9
}
