import CoreGraphics
import AppKit

/// Posts synthetic keyboard events to whatever app currently has focus.
/// Requires the Accessibility permission.
enum TextInjector {
    private static let source = CGEventSource(stateID: .combinedSessionState)

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
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func pressKey(_ keyCode: CGKeyCode, times: Int = 1) {
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static let backspaceKey: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36
}
