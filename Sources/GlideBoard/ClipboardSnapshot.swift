import AppKit

/// Full copy of the pasteboard's current items, so the paste-over-selection
/// fallback can use the clipboard as a vehicle without the user losing what
/// they had copied.
struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]

    init(of pasteboard: NSPasteboard = .general) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
