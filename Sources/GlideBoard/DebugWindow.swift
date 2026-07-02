import AppKit

/// Live model console: docked next to the keyboard panel (child window, moves
/// with it). One card per query plus aggregate stats, built for deciding
/// where to tune: context, model, or cleaner.
final class ModelConsole {
    let panel: NSPanel
    private let stack = NSStackView()
    private let statsField = NSTextField(labelWithString: "sin consultas todavía")

    private var phraseCount = 0, phraseMs = 0, phraseEmpty = 0
    private var phraseAccepted = 0
    private var wordCount = 0, wordMs = 0, wordEmpty = 0
    private var queries: [ModelQuery] = []

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

        let copyAllButton = CopyButton(title: "copiar todo")
        copyAllButton.payload = { [weak self] in self?.formatAll() ?? "" }

        let clearButton = NSButton(title: "limpiar", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .inline
        clearButton.font = NSFont.systemFont(ofSize: 10)

        let header = NSStackView(views: [title, NSView(), copyAllButton, clearButton])
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
        queries.removeAll()
        phraseCount = 0; phraseMs = 0; phraseEmpty = 0
        phraseAccepted = 0
        wordCount = 0; wordMs = 0; wordEmpty = 0
        statsField.stringValue = "sin consultas todavía"
    }

    /// Plain-text rendering of a single query, for the clipboard.
    private func format(_ q: ModelQuery) -> String {
        """
        [\(q.kind)] \(q.ms)ms · \(q.engine) · \(q.source) · \(Self.timeFormat.string(from: q.date))
        ctx: \(q.context)
        raw: \(q.raw)
        →:   \(q.cleaned)
        """
    }

    /// Newest-first dump of every retained query.
    private func formatAll() -> String {
        queries.reversed().map(format).joined(separator: "\n\n")
    }

    func record(_ q: ModelQuery) {
        if q.isPhrase {
            phraseCount += 1; phraseMs += q.ms; if q.isEmpty { phraseEmpty += 1 }
        } else {
            wordCount += 1; wordMs += q.ms; if q.isEmpty { wordEmpty += 1 }
        }
        updateStats()
        queries.append(q)
        let card = makeCard(q)
        stack.insertArrangedSubview(card, at: 0)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        while stack.arrangedSubviews.count > 30 {
            stack.arrangedSubviews.last?.removeFromSuperview()
            if !queries.isEmpty { queries.removeFirst() }
        }
    }

    func recordPhraseAccepted() {
        phraseAccepted += 1
        updateStats()
    }

    private func updateStats() {
        var parts: [String] = []
        if phraseCount > 0 {
            let shown = max(1, phraseCount - phraseEmpty)
            parts.append("✦ n=\(phraseCount) μ=\(phraseMs / phraseCount)ms vacías=\(phraseEmpty * 100 / phraseCount)% aceptadas=\(phraseAccepted * 100 / shown)%")
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

        let copyBtn = CopyButton(title: "copiar")
        copyBtn.payload = { [weak self] in self?.format(q) ?? "" }
        let headerRow = NSStackView(views: [headerField, NSView(), copyBtn])
        headerRow.orientation = .horizontal
        headerRow.spacing = 4

        let inner = NSStackView(views: [headerRow, contextField, rawField, cleanField])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
            headerRow.widthAnchor.constraint(equalTo: inner.widthAnchor)
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

/// Inline button that copies a lazily-computed string to the pasteboard,
/// flashing a "✓ copiado" confirmation.
final class CopyButton: NSButton {
    var payload: () -> String = { "" }
    private var resetTitle = "copiar"

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        resetTitle = title
        bezelStyle = .inline
        font = NSFont.systemFont(ofSize: 10)
        target = self
        action = #selector(copyPayload)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyPayload() {
        let text = payload()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        title = "✓ copiado"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.title = self.resetTitle
        }
    }
}

/// Plain history of the text actually inserted into the focused app — no model
/// queries, no prompts. Docked to the left of the keyboard panel. One copy
/// button per entry plus a copy-all in the header.
final class TextHistoryConsole {
    let panel: NSPanel
    private let stack = NSStackView()
    private var entries: [(text: String, date: Date)] = []

    /// Every entry is also appended to disk, so sent text survives app
    /// restarts and any delivery failure — it must never be unrecoverable.
    private struct StoredEntry: Codable {
        let date: Date
        let text: String
    }

    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("typed-history.jsonl")
    }()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
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

        let title = NSTextField(labelWithString: "texto introducido")
        title.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)

        let copyAllButton = CopyButton(title: "copiar todo")
        copyAllButton.payload = { [weak self] in self?.formatAll() ?? "" }

        let clearButton = NSButton(title: "limpiar", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .inline
        clearButton.font = NSFont.systemFont(ofSize: 10)

        let header = NSStackView(views: [title, NSView(), copyAllButton, clearButton])
        header.orientation = .horizontal

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
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

        let main = NSStackView(views: [header, scroll])
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
        panel.setFrame(NSRect(x: f.minX - 320 - 10, y: f.minY,
                              width: 320, height: max(440, f.height)), display: true)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Data

    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = (text: trimmed, date: Date())
        persist(entry)
        append(entry)
    }

    private func append(_ entry: (text: String, date: Date)) {
        entries.append(entry)
        let card = makeCard(entry)
        stack.insertArrangedSubview(card, at: 0)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        while stack.arrangedSubviews.count > 100 {
            stack.arrangedSubviews.last?.removeFromSuperview()
            if !entries.isEmpty { entries.removeFirst() }
        }
    }

    private func persist(_ entry: (text: String, date: Date)) {
        guard var line = try? JSONEncoder().encode(StoredEntry(date: entry.date,
                                                               text: entry.text)) else { return }
        line.append(0x0A)
        let url = Self.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Reload the most recent persisted entries (newest ends up on top).
    func loadPersisted(limit: Int = 100) {
        guard let contents = try? String(contentsOf: Self.logURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in contents.split(separator: "\n").suffix(limit) {
            guard let stored = try? decoder.decode(StoredEntry.self, from: Data(line.utf8)) else { continue }
            append((text: stored.text, date: stored.date))
        }
    }

    @objc private func clearLog() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
    }

    private func formatAll() -> String {
        entries.reversed().map { $0.text }.joined(separator: "\n")
    }

    private func makeCard(_ entry: (text: String, date: Date)) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        card.layer?.cornerRadius = 8

        let stamp = NSTextField(labelWithString: Self.timeFormat.string(from: entry.date))
        stamp.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        stamp.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)

        let copyBtn = CopyButton(title: "copiar")
        copyBtn.payload = { entry.text }

        let headerRow = NSStackView(views: [stamp, NSView(), copyBtn])
        headerRow.orientation = .horizontal
        headerRow.spacing = 4

        let body = NSTextField(labelWithString: entry.text)
        body.font = NSFont.systemFont(ofSize: 12)
        body.textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inner = NSStackView(views: [headerRow, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
            headerRow.widthAnchor.constraint(equalTo: inner.widthAnchor),
            body.widthAnchor.constraint(equalTo: inner.widthAnchor)
        ])
        return card
    }
}
