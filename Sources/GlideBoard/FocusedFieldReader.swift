import AppKit
import ApplicationServices

/// Reads the real content of the focused text field via the Accessibility
/// API, so the completion model sees the actual text — including anything
/// typed with the physical keyboard or already present in the field.
enum FocusedFieldReader {
    /// Text before the caret in the focused UI element, or nil if the app
    /// doesn't expose it (then the caller falls back to its own transcript).
    static func textBeforeCursor(maxLength: Int = 450) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        // Never read password fields.
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }

        // Caret position (AX ranges are UTF-16 based; use NSString throughout).
        let ns = text as NSString
        var caret = ns.length
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                         &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) {
                caret = range.location
            }
        }

        let location = min(max(0, caret), ns.length)
        let start = max(0, location - maxLength)
        let slice = ns.substring(with: NSRange(location: start, length: location - start))
        return slice.isEmpty ? nil : slice
    }
}
