import AppKit
import ApplicationServices

/// Reads the real content of the focused text field via the Accessibility
/// API, so the completion model sees the actual text — including anything
/// typed with the physical keyboard or already present in the field.
enum FocusedFieldReader {
    /// Electron/Chromium apps don't build their accessibility tree until an
    /// assistive client asks for it. Setting AXManualAccessibility turns it
    /// on (documented Electron behavior). Remember which pids we've enabled.
    private static var enabledPids = Set<pid_t>()

    private static func enableElectronAccessibilityIfNeeded(in app: NSRunningApplication? = nil) {
        guard let app = app ?? NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard !enabledPids.contains(pid) else { return }
        enabledPids.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement,
                                     "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    static func isEditableTextTarget(role: String?, supportsTextSelection: Bool) -> Bool {
        guard let role else { return false }
        return supportsTextSelection
            || role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    /// Whether the target app's focused element can currently receive text.
    static func hasEditableTextTarget(in app: NSRunningApplication?) -> Bool {
        guard let app, !app.isTerminated else { return false }
        enableElectronAccessibilityIfNeeded(in: app)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return false }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var attributes: CFArray?
        let attributesResult = AXUIElementCopyAttributeNames(element, &attributes)
        let names = attributes as? [String] ?? []
        return isEditableTextTarget(role: roleRef as? String,
                                    supportsTextSelection: attributesResult == .success
                                        && names.contains(kAXSelectedTextRangeAttribute as String))
    }

    /// Text before the caret in the focused UI element, or nil if the app
    /// doesn't expose it (then the caller falls back to its own transcript).
    static func textBeforeCursor(maxLength: Int = 450) -> String? {
        enableElectronAccessibilityIfNeeded()
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
              let text = valueRef as? String, !text.isEmpty else {
            // Web content often has no AXValue: read by range instead.
            return stringBeforeCaretViaRange(element, maxLength: maxLength)
        }

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

    /// Fallback for fields without AXValue (Chromium/Electron web content):
    /// ask for the string in the range [caret - maxLength, caret].
    private static func stringBeforeCaretViaRange(_ element: AXUIElement, maxLength: Int) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &selection),
              selection.location > 0 else { return nil }

        var want = CFRange(location: max(0, selection.location - maxLength),
                           length: min(selection.location, maxLength))
        guard let wantValue = AXValueCreate(.cfRange, &want) else { return nil }
        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            wantValue, &stringRef) == .success,
              let text = stringRef as? String, !text.isEmpty else { return nil }
        return text
    }
}
