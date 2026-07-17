import AppKit
import Carbon

/// Numa's global action palette: a transient nonactivating panel with a
/// search field and the action catalog. The target app keeps AX focus; the
/// panel only takes key status for typing, exactly like the composer.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    private let catalog: NumaActionCatalog
    private let contextProvider: () -> String?
    private let screenProvider: () -> NSScreen?

    private let panel: FloatingPanel
    private let contentView: PaletteContentView
    private var results: [NumaActionCatalog.ResolvedAction] = []
    private var selectedIndex = 0
    /// Top edge stays fixed while the panel grows or shrinks with results.
    private var topY: CGFloat = 0
    private var resignKeyObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }

    init(catalog: NumaActionCatalog,
         context: @escaping () -> String?,
         screen: @escaping () -> NSScreen?)
    {
        self.catalog = catalog
        self.contextProvider = context
        self.screenProvider = screen

        contentView = PaletteContentView()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteMetrics.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = contentView
        super.init()

        contentView.searchField.delegate = self
        contentView.onRowClicked = { [weak self] index in
            self?.select(index)
            self?.execute(entryAt: index)
        }
        // A transient panel: losing key status (click elsewhere) dismisses it.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel,
            queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    deinit {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        contentView.searchField.stringValue = ""
        contentView.contextName = contextProvider()
        refreshResults()
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(contentView.searchField)
        if let editor = panel.fieldEditor(true, for: contentView.searchField)
            as? NSTextView {
            editor.insertionPointColor = .white
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        contentView.clearTransientMessage()
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
    }

    // MARK: - Results

    private func refreshResults() {
        let entries = catalog.resolvedActions()
            .filter { $0.descriptor.showsInPalette }
        results = PaletteSearch.results(query: contentView.searchField.stringValue,
                                        entries: entries,
                                        recents: Settings.paletteRecents)
        selectedIndex = 0
        contentView.setResults(results, selectedIndex: selectedIndex)
        resizeToFit()
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        contentView.updateSelection(selectedIndex)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        select(min(max(0, selectedIndex + delta), results.count - 1))
    }

    private func execute(entryAt index: Int) {
        guard results.indices.contains(index) else { return }
        let entry = results[index]
        guard entry.availability.isAvailable else {
            contentView.showTransientMessage(
                entry.availability.reason ?? "Not available right now")
            return
        }
        let id = entry.descriptor.id
        hide()
        // Give the window server a beat to hand key status back to the
        // target app before actions that type or read its focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let outcome = self.catalog.execute(id, from: .palette)
            switch outcome {
            case .completed, .openedSurface:
                var recents = Settings.paletteRecents
                recents.removeAll { $0 == id.rawValue }
                recents.insert(id.rawValue, at: 0)
                Settings.paletteRecents = recents
            case .unavailable(let reason), .failed(let reason),
                 .requiresConfirmation(let reason):
                NSLog("Numa palette: %@ — %@", id.rawValue, reason)
                NSSound.beep()
            }
        }
    }

    // MARK: - Geometry

    private func position() {
        guard let screen = screenProvider() else { return }
        let visible = screen.visibleFrame
        topY = visible.maxY - visible.height * 0.16
        let height = contentView.fittingHeight(for: results.count)
        panel.setFrame(NSRect(x: visible.midX - PaletteMetrics.width / 2,
                              y: topY - height,
                              width: PaletteMetrics.width,
                              height: height),
                       display: true)
    }

    private func resizeToFit() {
        guard panel.isVisible || topY != 0 else { return }
        let height = contentView.fittingHeight(for: results.count)
        var frame = panel.frame
        frame.origin.y = topY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    // MARK: - NSTextFieldDelegate

    public func controlTextDidChange(_ notification: Notification) {
        refreshResults()
    }

    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            execute(entryAt: selectedIndex)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }
}

// MARK: - Visual constants

enum PaletteMetrics {
    static let width: CGFloat = 560
    static let headerHeight: CGFloat = 54
    static let rowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 28
    static let maxVisibleRows = 7
    static let emptyStateHeight: CGFloat = 64
    static let horizontalInset: CGFloat = 10

    static let accent = NSColor(calibratedRed: 0.40, green: 0.67, blue: 1.0, alpha: 1)
    static let voiceGreen = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.44, alpha: 1)
    static let title = NSColor.white
    static let subtitle = NSColor(calibratedWhite: 0.72, alpha: 1)
    static let faint = NSColor(calibratedWhite: 1.0, alpha: 0.38)
    static let warning = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.35, alpha: 1)

    static func tint(for category: NumaActionCategory) -> NSColor {
        switch category {
        case .board: accent
        case .dictation: voiceGreen
        case .text: NSColor(calibratedRed: 0.75, green: 0.55, blue: 1.0, alpha: 1)
        case .attention: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)
        case .system: NSColor(calibratedWhite: 0.80, alpha: 1)
        }
    }
}

// MARK: - Content view

/// Manual, fully deterministic layout: header (orb, search, context chip),
/// separator, scrolling results, footer with key hints.
final class PaletteContentView: NSView {
    let searchField = PaletteSearchField()
    var contextName: String? { didSet { updateContextChip() } }
    var onRowClicked: ((Int) -> Void)?

    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let orb = PaletteOrbView()
    private let contextChip = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let rowsContainer = PaletteResultsContainer()
    private let emptyLabel = NSTextField(labelWithString: "No matching actions")
    private let footerLabel = NSTextField(labelWithString: "")
    private let footerHint = "↑↓ navigate   ↩ run   esc close   ⌥⌥ toggle"
    private var rowViews: [PaletteRowView] = []
    private var transientWork: DispatchWorkItem?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: PaletteMetrics.width, height: 200))
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        addSubview(background)
        tint.wantsLayer = true
        tint.layer?.backgroundColor =
            NSColor(calibratedWhite: 0.07, alpha: 0.62).cgColor
        addSubview(tint)

        addSubview(orb)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16, weight: .medium)
        searchField.textColor = PaletteMetrics.title
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search Numa actions…",
            attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                         .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.34)])
        addSubview(searchField)

        contextChip.font = .systemFont(ofSize: 11, weight: .medium)
        contextChip.textColor = PaletteMetrics.subtitle
        contextChip.alignment = .center
        contextChip.wantsLayer = true
        contextChip.layer?.backgroundColor =
            NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        contextChip.layer?.cornerRadius = 9
        addSubview(contextChip)

        separator.wantsLayer = true
        separator.layer?.backgroundColor =
            NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        addSubview(separator)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = rowsContainer
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = PaletteMetrics.faint
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        footerLabel.font = .systemFont(ofSize: 10, weight: .medium)
        footerLabel.textColor = PaletteMetrics.faint
        footerLabel.stringValue = footerHint
        addSubview(footerLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fittingHeight(for resultCount: Int) -> CGFloat {
        let resultsHeight = resultCount == 0
            ? PaletteMetrics.emptyStateHeight
            : CGFloat(min(resultCount, PaletteMetrics.maxVisibleRows))
                * PaletteMetrics.rowHeight
        return PaletteMetrics.headerHeight + 1 + resultsHeight
            + PaletteMetrics.footerHeight
    }

    func setResults(_ results: [NumaActionCatalog.ResolvedAction],
                    selectedIndex: Int) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = results.enumerated().map { index, entry in
            let row = PaletteRowView(entry: entry)
            row.onClick = { [weak self] in self?.onRowClicked?(index) }
            rowsContainer.addSubview(row)
            return row
        }
        emptyLabel.isHidden = !results.isEmpty
        updateSelection(selectedIndex)
        needsLayout = true
    }

    func updateSelection(_ selectedIndex: Int) {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selectedIndex
        }
        guard rowViews.indices.contains(selectedIndex) else { return }
        rowsContainer.scrollToVisible(rowViews[selectedIndex].frame)
    }

    func showTransientMessage(_ message: String) {
        transientWork?.cancel()
        footerLabel.stringValue = message
        footerLabel.textColor = PaletteMetrics.warning
        let work = DispatchWorkItem { [weak self] in self?.clearTransientMessage() }
        transientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    func clearTransientMessage() {
        transientWork?.cancel()
        transientWork = nil
        footerLabel.stringValue = footerHint
        footerLabel.textColor = PaletteMetrics.faint
    }

    private func updateContextChip() {
        if let name = contextName, !name.isEmpty {
            contextChip.stringValue = "→ \(name)"
            contextChip.isHidden = false
        } else {
            contextChip.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        tint.frame = bounds

        let header = NSRect(x: 0, y: 0, width: bounds.width,
                            height: PaletteMetrics.headerHeight)
        orb.frame = NSRect(x: 18, y: header.midY - 11, width: 22, height: 22)

        var chipWidth: CGFloat = 0
        if !contextChip.isHidden {
            chipWidth = min(contextChip.intrinsicContentSize.width + 20, 180)
            contextChip.frame = NSRect(x: bounds.width - chipWidth - 16,
                                       y: header.midY - 9,
                                       width: chipWidth, height: 18)
        }
        let fieldRight = contextChip.isHidden
            ? bounds.width - 18
            : bounds.width - chipWidth - 26
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(x: 52, y: header.midY - fieldHeight / 2,
                                   width: fieldRight - 52, height: fieldHeight)

        separator.frame = NSRect(x: 0, y: PaletteMetrics.headerHeight,
                                 width: bounds.width, height: 1)

        let resultsTop = PaletteMetrics.headerHeight + 1
        let resultsHeight = bounds.height - resultsTop - PaletteMetrics.footerHeight
        scrollView.frame = NSRect(x: 0, y: resultsTop,
                                  width: bounds.width, height: resultsHeight)
        emptyLabel.frame = NSRect(x: 0, y: resultsTop + resultsHeight / 2 - 9,
                                  width: bounds.width, height: 18)

        rowsContainer.frame = NSRect(
            x: 0, y: 0, width: bounds.width,
            height: max(resultsHeight,
                        CGFloat(rowViews.count) * PaletteMetrics.rowHeight))
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(x: PaletteMetrics.horizontalInset,
                               y: CGFloat(index) * PaletteMetrics.rowHeight,
                               width: bounds.width - PaletteMetrics.horizontalInset * 2,
                               height: PaletteMetrics.rowHeight)
        }

        footerLabel.frame = NSRect(x: 20,
                                   y: bounds.height - PaletteMetrics.footerHeight + 5,
                                   width: bounds.width - 40, height: 15)
    }
}

/// NSTextField that keeps accepting the first click even though the panel
/// was not key yet. Editing shortcuts normally arrive through an app's Edit
/// menu; Numa is an accessory app with a non-activating panel, so the
/// standard commands are routed to the field editor directly (same pattern
/// as ComposerTextView).
final class PaletteSearchField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let editor = currentEditor() as? NSTextView else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags
            .intersection([.command, .control, .option, .shift])

        if key == "z", modifiers == [.command, .shift] {
            editor.undoManager?.redo()
            return true
        }
        guard modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a": editor.selectAll(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "v": editor.paste(nil)
        case "z": editor.undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Flipped container so row 0 sits at the top of the scroll area.
private final class PaletteResultsContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Small gradient orb: Numa's identity mark in the palette header.
private final class PaletteOrbView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(
            starting: PaletteMetrics.accent,
            ending: NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.74, alpha: 1))
        gradient?.draw(in: NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)),
                       angle: 60)
        if let symbol = NSImage(systemSymbolName: "command",
                                accessibilityDescription: "Numa") {
            let tinted = symbol.withSymbolConfiguration(
                .init(pointSize: 11, weight: .semibold))
            let size = NSSize(width: 11, height: 11)
            let origin = NSPoint(x: bounds.midX - size.width / 2,
                                 y: bounds.midY - size.height / 2)
            NSColor.white.set()
            tinted?.draw(in: NSRect(origin: origin, size: size), from: .zero,
                         operation: .sourceOver, fraction: 0.95)
        }
    }
}

// MARK: - Row

final class PaletteRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { refreshSelection() }
    }

    private let entry: NumaActionCatalog.ResolvedAction
    private let iconContainer = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let voiceIcon = NSImageView()
    private var keycaps: [NSTextField] = []
    private var hovered = false

    init(entry: NumaActionCatalog.ResolvedAction) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        let tint = PaletteMetrics.tint(for: entry.descriptor.category)
        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 8
        iconContainer.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        addSubview(iconContainer)

        iconView.image = NSImage(systemSymbolName: entry.descriptor.symbolName,
                                 accessibilityDescription: entry.descriptor.title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        iconView.contentTintColor = tint
        iconContainer.addSubview(iconView)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = PaletteMetrics.title
        titleField.stringValue = entry.descriptor.title
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.lineBreakMode = .byTruncatingTail
        if entry.availability.isAvailable {
            subtitleField.textColor = PaletteMetrics.subtitle
            subtitleField.stringValue = entry.descriptor.subtitle
        } else {
            subtitleField.textColor = PaletteMetrics.warning
            subtitleField.stringValue = entry.availability.reason
                ?? entry.descriptor.subtitle
        }
        addSubview(subtitleField)

        if let phrase = entry.voicePhrase, !phrase.isEmpty {
            voiceIcon.image = NSImage(systemSymbolName: "waveform",
                                      accessibilityDescription: "Voice command")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            voiceIcon.contentTintColor = PaletteMetrics.voiceGreen
            voiceIcon.toolTip = "«\(phrase)»"
            addSubview(voiceIcon)
        } else {
            voiceIcon.isHidden = true
        }

        // Keycaps render only when the user configured a shortcut: an
        // unconfigured action shows no shortcut metadata at all.
        if let shortcut = entry.shortcut {
            for part in Self.keycapParts(keyCode: shortcut.keyCode,
                                         modifiers: shortcut.modifiers) {
                let cap = NSTextField(labelWithString: part)
                cap.font = .systemFont(ofSize: 11, weight: .medium)
                cap.textColor = NSColor(calibratedWhite: 1, alpha: 0.75)
                cap.alignment = .center
                cap.wantsLayer = true
                cap.layer?.backgroundColor =
                    NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
                cap.layer?.cornerRadius = 4
                cap.layer?.borderWidth = 1
                cap.layer?.borderColor =
                    NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
                addSubview(cap)
                keycaps.append(cap)
            }
        }

        if !entry.availability.isAvailable {
            iconContainer.alphaValue = 0.45
            titleField.alphaValue = 0.55
        }

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func keycapParts(keyCode: UInt32, modifiers: UInt32) -> [String] {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts
    }

    override func layout() {
        super.layout()
        iconContainer.frame = NSRect(x: 10, y: bounds.midY - 14, width: 28, height: 28)
        iconView.frame = iconContainer.bounds.insetBy(dx: 5, dy: 5)

        var rightEdge = bounds.width - 12
        for cap in keycaps.reversed() {
            let width = max(cap.intrinsicContentSize.width + 10, 20)
            cap.frame = NSRect(x: rightEdge - width, y: bounds.midY - 9,
                               width: width, height: 18)
            rightEdge -= width + 4
        }
        if !voiceIcon.isHidden {
            voiceIcon.frame = NSRect(x: rightEdge - 18, y: bounds.midY - 8,
                                     width: 16, height: 16)
            rightEdge -= 24
        }

        let textWidth = rightEdge - 50 - 8
        titleField.frame = NSRect(x: 50, y: 6, width: textWidth, height: 17)
        subtitleField.frame = NSRect(x: 50, y: 24, width: textWidth, height: 15)
    }

    override var isFlipped: Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshSelection()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshSelection()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func refreshSelection() {
        if isSelected {
            layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        } else if hovered {
            layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.045).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
