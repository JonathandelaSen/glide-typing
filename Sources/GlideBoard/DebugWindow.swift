import AppKit

/// Live model console: docked next to the keyboard panel (child window, moves
/// with it). One card per query plus aggregate stats, built for deciding
/// where to tune: context, model, or cleaner.
final class ModelConsole {
    let panel: NSPanel
    private let stack = NSStackView()
    private let statsField = NSTextField(labelWithString: "sin consultas todavía")

    private var phraseCount = 0, phraseMs = 0, phraseEmpty = 0
    private var wordCount = 0, wordMs = 0, wordEmpty = 0

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.97).cgColor
        root.layer?.cornerRadius = 12
        panel.contentView = root

        let title = NSTextField(labelWithString: "consola del modelo")
        title.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)

        let clearButton = NSButton(title: "limpiar", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .inline
        clearButton.font = NSFont.systemFont(ofSize: 10)

        let header = NSStackView(views: [title, NSView(), clearButton])
        header.orientation = .horizontal

        statsField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statsField.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        statsField.maximumNumberOfLines = 2

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipView()
        let scroll = NSScrollView()
        scroll.contentView = flipped
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor)
        ])

        let main = NSStackView(views: [header, statsField, scroll])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 8
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: main.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: main.widthAnchor)
        ])
    }

    // MARK: - Docking

    func attach(to parent: NSWindow) {
        if panel.parent != parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        reposition(relativeTo: parent)
        panel.orderFront(nil)
    }

    func reposition(relativeTo parent: NSWindow) {
        let f = parent.frame
        panel.setFrame(NSRect(x: f.maxX + 10, y: f.minY,
                              width: 360, height: max(440, f.height)), display: true)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Data

    @objc private func clearLog() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        phraseCount = 0; phraseMs = 0; phraseEmpty = 0
        wordCount = 0; wordMs = 0; wordEmpty = 0
        statsField.stringValue = "sin consultas todavía"
    }

    func record(_ q: ModelQuery) {
        if q.isPhrase {
            phraseCount += 1; phraseMs += q.ms; if q.isEmpty { phraseEmpty += 1 }
        } else {
            wordCount += 1; wordMs += q.ms; if q.isEmpty { wordEmpty += 1 }
        }
        updateStats()
        let card = makeCard(q)
        stack.insertArrangedSubview(card, at: 0)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        while stack.arrangedSubviews.count > 30 {
            stack.arrangedSubviews.last?.removeFromSuperview()
        }
    }

    private func updateStats() {
        var parts: [String] = []
        if phraseCount > 0 {
            parts.append("✦ n=\(phraseCount) μ=\(phraseMs / phraseCount)ms vacías=\(phraseEmpty * 100 / phraseCount)%")
        }
        if wordCount > 0 {
            parts.append("palabra n=\(wordCount) μ=\(wordMs / wordCount)ms vacías=\(wordEmpty * 100 / wordCount)%")
        }
        statsField.stringValue = parts.joined(separator: "   ")
    }

    // MARK: - Cards

    private func makeCard(_ q: ModelQuery) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        card.layer?.cornerRadius = 8

        let latencyColor: NSColor = q.ms < 450
            ? NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
            : (q.ms < 900 ? NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.4, alpha: 1)
                          : NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.45, alpha: 1))

        let header = NSMutableAttributedString()
        header.append(NSAttributedString(string: q.kind, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: q.isPhrase
                ? NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
                : NSColor(calibratedWhite: 0.9, alpha: 1)
        ]))
        header.append(NSAttributedString(string: "  \(q.ms) ms", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: latencyColor
        ]))
        header.append(NSAttributedString(
            string: "  \(q.engine) · \(q.source) · \(Self.timeFormat.string(from: q.date))",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)
            ]))

        let headerField = makeField(header)
        let contextField = makeField(line("ctx", q.context, color: NSColor(calibratedWhite: 0.6, alpha: 1)))
        contextField.maximumNumberOfLines = 3
        let rawField = makeField(line("raw", q.raw, color: NSColor(calibratedWhite: 0.78, alpha: 1)))
        rawField.maximumNumberOfLines = 2
        let resultColor: NSColor = q.isEmpty
            ? NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.45, alpha: 1)
            : NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
        let cleanField = makeField(line("→", q.cleaned, color: resultColor))
        cleanField.maximumNumberOfLines = 2

        let inner = NSStackView(views: [headerField, contextField, rawField, cleanField])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7)
        ])
        return card
    }

    private func line(_ tag: String, _ text: String, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: tag + "  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)
        ]))
        s.append(NSAttributedString(string: text.isEmpty ? "—" : text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color
        ]))
        return s
    }

    private func makeField(_ attributed: NSAttributedString) -> NSTextField {
        let f = NSTextField(labelWithAttributedString: attributed)
        f.isSelectable = true
        f.lineBreakMode = .byTruncatingTail
        f.allowsDefaultTighteningForTruncation = true
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }
}

/// Clip view that anchors content to the top (newest cards first).
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
