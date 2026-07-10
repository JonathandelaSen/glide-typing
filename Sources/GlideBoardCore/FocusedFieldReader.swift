import AppKit
import ApplicationServices

/// Reads the real content of the focused text field via the Accessibility
/// API, so the completion model sees the actual text — including anything
/// typed with the physical keyboard or already present in the field.
enum FocusedFieldReader {
    enum TextTargetStatus {
        case editable
        case notEditable
        case unknown

        var canAttemptInsertion: Bool {
            self != .notEditable
        }
    }

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

    static func textTargetStatus(role: String?, supportsTextSelection: Bool) -> TextTargetStatus {
        guard let role else { return .unknown }
        return isEditableTextTarget(role: role, supportsTextSelection: supportsTextSelection)
            ? .editable
            : .notEditable
    }

    /// Whether the target app's focused element can currently receive text.
    static func textTargetStatus(in app: NSRunningApplication?) -> TextTargetStatus {
        guard let app, !app.isTerminated else { return .unknown }
        enableElectronAccessibilityIfNeeded(in: app)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return .unknown }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return .unknown
        }

        var rangeRef: CFTypeRef?
        let supportsTextSelection = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success
        return textTargetStatus(role: roleRef as? String,
                                supportsTextSelection: supportsTextSelection)
    }

    static func hasEditableTextTarget(in app: NSRunningApplication?) -> Bool {
        textTargetStatus(in: app).canAttemptInsertion
    }

    /// pid of the process owning the system-wide focused UI element — where
    /// keyboard events are actually routed — or nil if AX can't tell.
    static func systemFocusPid() -> pid_t? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focusedRef as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    /// One-line description of where the text will land, built from facts the
    /// AX tree exposes: app name, focused window title, and the focused
    /// field's label or placeholder. Window titles carry the payload — mail
    /// subject, chat channel, document name — which disambiguates tone and
    /// vocabulary for the completion model. Nil when nothing useful is found.
    static func targetDescription(in app: NSRunningApplication?) -> String? {
        guard let app, !app.isTerminated else { return nil }
        enableElectronAccessibilityIfNeeded(in: app)
        var parts: [String] = []
        if let name = app.localizedName, !name.isEmpty { parts.append(name) }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                         &windowRef) == .success,
           let windowRef {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowRef as! AXUIElement,
                                             kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                parts.append(title)
            }
        }

        // The field's own label or placeholder ("To:", "Message #dev"…),
        // when the app names it and it adds something new.
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString,
                                         &focusedRef) == .success,
           let focusedRef {
            let element = focusedRef as! AXUIElement
            for attr in ["AXTitle", "AXPlaceholderValue", "AXDescription"] {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
                   let label = ref as? String, !label.isEmpty, !parts.contains(label) {
                    parts.append(label)
                    break
                }
            }
        }

        let summary = parts.joined(separator: " — ")
        return summary.isEmpty ? nil : String(summary.prefix(120))
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

    // MARK: - Selection (transform-anywhere)

    /// Focused UI element of `app` (or the system-wide one), with the same
    /// secure-field veto as `textBeforeCursor`. Shared by the selection accessors.
    private static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        enableElectronAccessibilityIfNeeded(in: app)
        let owner: AXUIElement
        if let app, !app.isTerminated {
            owner = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            owner = AXUIElementCreateSystemWide()
        }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString,
                                         &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        return element
    }

    /// What a transformation operates on, which decides how to write back.
    enum SelectionScope {
        case selection   // replace via AXSelectedText
        case wholeField  // empty selection: the whole field, via AXValue
    }

    /// The selected text in the focused element — or, when nothing is
    /// selected, the whole field content. Nil when AX exposes neither.
    static func transformableText(in app: NSRunningApplication?) -> (text: String, scope: SelectionScope)? {
        guard let element = focusedElement(in: app) else { return nil }
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                         &selectedRef) == .success,
           let selected = selectedRef as? String, !selected.isEmpty {
            return (selected, .selection)
        }
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                         &valueRef) == .success,
           let value = valueRef as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (value, .wholeField)
        }
        return nil
    }

    /// Write the transformed text back via AX. Returns false when the app
    /// doesn't allow it (the caller falls back to paste-over-selection).
    static func replaceTransformableText(_ text: String, scope: SelectionScope,
                                         in app: NSRunningApplication?) -> Bool {
        guard let element = focusedElement(in: app) else { return false }
        let attribute = (scope == .selection ? kAXSelectedTextAttribute
                                             : kAXValueAttribute) as CFString
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, attribute, text as CFString) == .success
    }

    // MARK: - Surrounding context (prompt-anywhere)

    /// Visible text around the focused field — chat messages, quoted emails —
    /// collected from the AX tree with a hard character cap and deadline: the
    /// tree can be huge and slow, so this samples rather than walks it whole.
    /// Everything returned ends up in the debug console via the prompt body,
    /// so the user can audit exactly what was read.
    static func surroundingContext(in app: NSRunningApplication?,
                                   maxLength: Int = 1500,
                                   timeout: TimeInterval = 0.15) -> String? {
        guard let focused = focusedElement(in: app) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)

        // Climb a few levels: siblings near the field carry the conversation.
        var root = focused
        for _ in 0..<5 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXParentAttribute as CFString,
                                                &parentRef) == .success,
                  let parentRef, Date() < deadline else { break }
            let parent = parentRef as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            root = parent
            if (roleRef as? String) == (kAXWindowRole as String) { break }
        }

        var pieces: [String] = []
        var seen = Set<String>()
        var collected = 0
        var visited = 0
        collectText(from: root, skipping: focused, deadline: deadline,
                    depth: 0, visited: &visited,
                    pieces: &pieces, seen: &seen, collected: &collected,
                    budget: maxLength)
        guard !pieces.isEmpty else { return nil }
        // Keep the tail: in chats and mails the recent content sits at the end.
        let joined = pieces.joined(separator: "\n")
        return String(joined.suffix(maxLength))
    }

    private static func collectText(from element: AXUIElement, skipping focused: AXUIElement,
                                    deadline: Date, depth: Int, visited: inout Int,
                                    pieces: inout [String], seen: inout Set<String>,
                                    collected: inout Int, budget: Int) {
        guard depth < 8, visited < 400, collected < budget, Date() < deadline,
              !CFEqual(element, focused) else { return }
        visited += 1

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String
        if role == (kAXStaticTextRole as String) || role == (kAXTextAreaRole as String) {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                             &valueRef) == .success,
               let value = valueRef as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 2, seen.insert(text).inserted {
                    pieces.append(String(text.prefix(400)))
                    collected += min(text.count, 400)
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children.prefix(30) {
            collectText(from: child, skipping: focused, deadline: deadline,
                        depth: depth + 1, visited: &visited,
                        pieces: &pieces, seen: &seen, collected: &collected,
                        budget: budget)
            if collected >= budget || Date() >= deadline { return }
        }
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
