import AppKit
import ApplicationServices

/// The insertion point captured when dictation begins. Keeping this snapshot
/// separate from the current focus prevents the status overlay (or a later
/// app activation) from changing where the transcript lands.
enum DictationTarget {
    case composer(selection: NSRange, textBeforeSelection: String)
    case external(CapturedTextTarget)
    case fallback

    var destinationName: String {
        switch self {
        case .composer, .fallback:
            "Numa"
        case .external(let target):
            target.app.localizedName ?? "la aplicación"
        }
    }

    var textBeforeSelection: String {
        switch self {
        case .composer(_, let textBeforeSelection): textBeforeSelection
        case .external(let target): target.textBeforeSelection
        case .fallback: ""
        }
    }

    var replacesSelection: Bool {
        switch self {
        case .composer(let selection, _): selection.length > 0
        case .external(let target): target.replacesSelection
        case .fallback: false
        }
    }
}

/// A focused accessibility element plus its selection at dictation start.
/// The element is deliberately retained: Electron apps can report a different
/// focused element after the floating UI is shown, but this is the field in
/// which the user actually started dictating.
final class CapturedTextTarget {
    let app: NSRunningApplication
    private let element: AXUIElement
    private let selection: CFRange?
    let textBeforeSelection: String

    var replacesSelection: Bool { (selection?.length ?? 0) > 0 }

    private init(app: NSRunningApplication, element: AXUIElement,
                 selection: CFRange?, textBeforeSelection: String) {
        self.app = app
        self.element = element
        self.selection = selection
        self.textBeforeSelection = textBeforeSelection
    }

    /// `detail` describes what was found either way, for the dictation log.
    static func capture(in app: NSRunningApplication?) -> (target: CapturedTextTarget?, detail: String) {
        guard let app, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return (nil, "sin app externa activa")
        }
        let name = app.localizedName ?? "pid \(app.processIdentifier)"

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(appElement,
                                                     kAXFocusedUIElementAttribute as CFString,
                                                     &focusedRef)
        guard focusErr == .success, let focusedRef else {
            return (nil, "\(name): sin elemento enfocado (AXError \(focusErr.rawValue))")
        }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                            &roleRef) == .success,
              let role = roleRef as? String else {
            return (nil, "\(name): elemento enfocado sin rol")
        }

        var rangeRef: CFTypeRef?
        let hasSelectionRange = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success
        let hasEditableAncestor = FocusedFieldReader.elementHasEditableAncestor(element)
        let isChromium = FocusedFieldReader.elementIsChromiumNode(element)
        let facts = "\(name): rol \(role), rango \(hasSelectionRange), " +
                    "editableAncestor \(hasEditableAncestor), chromium \(isChromium)"
        guard FocusedFieldReader.isEditableTextTarget(
            role: role,
            supportsTextSelection: hasSelectionRange,
            hasEditableAncestor: hasEditableAncestor,
            isChromiumNode: isChromium
        ) else {
            return (nil, "\(facts) — no editable")
        }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString,
                                         &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return (nil, "\(facts) — campo seguro, vetado")
        }

        let selection = selectionRange(from: rangeRef)
        let textBeforeSelection = textBeforeSelection(in: element, selection: selection)
        return (CapturedTextTarget(app: app, element: element, selection: selection,
                                   textBeforeSelection: textBeforeSelection), facts)
    }

    /// Restore the original field and selection. The caller must activate the
    /// owning app first; doing this while it is backgrounded is unreliable in
    /// both AppKit and Electron applications. The selection restore is
    /// best-effort: an editor that rejects it still gets the text at its
    /// current caret, which beats dumping the transcript to the board.
    func prepareForInsertion() -> Bool {
        guard !app.isTerminated else { return false }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let selection else { return true }
        var range = selection
        if let value = AXValueCreate(.cfRange, &range),
           AXUIElementSetAttributeValue(element,
                                        kAXSelectedTextRangeAttribute as CFString,
                                        value) == .success {
            return true
        }
        DictationLog.write("selección no restaurada en \(app.localizedName ?? "?") — se teclea en el caret actual")
        return true
    }

    private static func selectionRange(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func textBeforeSelection(in element: AXUIElement, selection: CFRange?) -> String {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &valueRef) == .success,
              let text = valueRef as? String else { return "" }
        let ns = text as NSString
        let location = min(max(0, selection?.location ?? ns.length), ns.length)
        return ns.substring(to: location)
    }
}
