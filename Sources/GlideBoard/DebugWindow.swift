import AppKit

/// Developer window: shows, live, the exact context handed to the completion
/// model on every request, and what the model returned.
final class DebugWindowController: NSWindowController {
    private var textView: NSTextView!
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "GlideBoard — contexto del modelo (debug)"
        super.init(window: window)

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = window.contentView!.bounds
        scroll.autoresizingMask = [.width, .height]
        textView = (scroll.documentView as! NSTextView)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        window.contentView!.addSubview(scroll)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Newest entries on top; log capped so it never grows unbounded.
    func log(_ message: String) {
        let stamp = Self.timeFormat.string(from: Date())
        var text = "[\(stamp)] \(message)\n────\n" + textView.string
        if text.count > 30_000 {
            text = String(text.prefix(30_000))
        }
        textView.string = text
    }
}
