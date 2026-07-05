import AppKit

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didTap key: Key)
    func keyboardView(_ view: KeyboardView, didGlide points: [CGPoint])
    func keyboardView(_ view: KeyboardView, didUpdateGlide points: [CGPoint])
    func keyboardView(_ view: KeyboardView, didPickCandidate index: Int)
    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int)
    func keyboardView(_ view: KeyboardView, didPickGhost text: String)
    /// A glide ended on top of a candidate in the suggestion row.
    func keyboardView(_ view: KeyboardView, didGlideSelect index: Int)
    /// A two-finger swipe shortcut over the keyboard. `long` distinguishes a
    /// long flick (accept the whole ghost) from a short one (first word only).
    func keyboardView(_ view: KeyboardView, didFlick direction: FlickDirection, long: Bool)
    /// An editing action chosen from the right-click menu.
    func keyboardView(_ view: KeyboardView, didEdit action: EditAction)
    /// The user toggled between tap mode and drag (no-click glide) mode.
    func keyboardView(_ view: KeyboardView, didSetHoverGlide enabled: Bool)
    /// Held-down backspace auto-repeat. `byWord` is true once the hold has
    /// accelerated past the per-character phase.
    func keyboardView(_ view: KeyboardView, didRepeatBackspaceByWord byWord: Bool)
    /// Insert the composer buffer into the focused app.
    func keyboardView(_ view: KeyboardView, didRequestInsert pressReturn: Bool)
    /// Copy the composer buffer to the clipboard (used when there is no
    /// editable text target to inject into).
    func keyboardViewDidRequestCopy(_ view: KeyboardView)
    /// The ✨ chip: open the transform/instruction menu (plans A+B).
    func keyboardViewDidRequestTransform(_ view: KeyboardView)
    /// The composer grew or shrank: the panel must resize.
    func keyboardViewDidResize(_ view: KeyboardView)
    /// Show/hide the typed-text history panel.
    func keyboardViewDidToggleHistory(_ view: KeyboardView)
}

/// Two-finger swipe directions and their shortcut actions.
enum FlickDirection {
    case left   // delete word / character
    case right  // space
    case up     // accept the AI phrase completion
    case down   // period
}

/// Editing actions available from the right-click menu.
enum EditAction: CaseIterable {
    case paste
    case selectAllCopy
    case deleteToEnd
    case deleteToStart
    case deleteAll

    var title: String {
        switch self {
        case .paste: return "Pegar"
        case .selectAllCopy: return "Seleccionar todo y copiar"
        case .deleteToEnd: return "Borrar hasta el final"
        case .deleteToStart: return "Borrar hasta el principio"
        case .deleteAll: return "Borrar todo"
        }
    }
}

final class KeyboardView: NSView {
    weak var delegate: KeyboardViewDelegate?

    // Geometry
    static let baseUnit: CGFloat = 56
    let unit: CGFloat
    static let margin: CGFloat = 10
    /// Toolbar strip height: scales with the keyboard but never below a
    /// comfortably clickable/readable minimum.
    static func barHeight(unit: CGFloat) -> CGFloat {
        max(30, 30 * unit / baseUnit)
    }
    var barHeight: CGFloat { KeyboardView.barHeight(unit: unit) }
    /// Toolbar UI scale factor (floored at 1 so small keyboards keep legible buttons).
    private var uiScale: CGFloat { max(1, unit / KeyboardView.baseUnit) }
    static let ghostHeight: CGFloat = 38
    static let predictionHeight: CGFloat = 30
    static let candidateHeight: CGFloat = 36
    private let keyGap: CGFloat = 5

    private(set) var layout: KeyboardLayout
    private(set) var language: Language

    /// Alternatives for the last glided word (or live preview while gliding).
    var candidates: [String] = [] {
        didSet { needsDisplay = true }
    }
    /// Next-word predictions, shown in their own row above the candidates.
    var predictions: [String] = [] {
        didSet { needsDisplay = true }
    }
    /// AI phrase completion (ghost text), shown inline after the composer text.
    var ghost: String? {
        didSet {
            updateGhostLabel()
            updateComposerHeight()
            needsDisplay = true
        }
    }
    /// Composer mode: text is composed here and inserted into the app on demand.
    var composerEnabled = true {
        didSet {
            composerScroll?.isHidden = !composerEnabled
            updateComposerHeight()
            needsDisplay = true
        }
    }
    /// Whether the focused app currently has an editable text field to inject
    /// into. When false the composer's action chip becomes a copy button.
    var hasTextTarget = true {
        didSet { if oldValue != hasTextTarget { needsDisplay = true } }
    }
    /// Height of the top row — grows with the composer text (up to ~4 lines).
    private(set) var topRowHeight: CGFloat = KeyboardView.ghostHeight

    // Real text view: caret, selection, scrolling, mid-text editing.
    private(set) var composerView: NSTextView!
    private var composerScroll: NSScrollView!
    private var ghostLabel: NSTextField!
    private(set) var composerProgrammatic = false

    var composerString: String { composerView?.string ?? "" }

    var composerCaretAtEnd: Bool {
        guard let composerView else { return true }
        let range = composerView.selectedRange()
        return range.length == 0 && range.location == (composerView.string as NSString).length
    }

    var composerTextBeforeCaret: String {
        guard let composerView else { return "" }
        let ns = composerView.string as NSString
        let loc = min(composerView.selectedRange().location, ns.length)
        return ns.substring(to: loc)
    }

    func composerInsert(_ s: String) {
        composerProgrammatic = true
        composerView.insertText(s, replacementRange: composerView.selectedRange())
        composerProgrammatic = false
        composerContentChanged()
    }

    func composerDeleteBackward(_ count: Int) {
        composerProgrammatic = true
        for _ in 0..<count { composerView.deleteBackward(nil) }
        composerProgrammatic = false
        composerContentChanged()
    }

    func composerDeleteWord() {
        let ns = composerView.string as NSString
        var caret = min(composerView.selectedRange().location, ns.length)
        guard caret > 0 else { return }
        let ws = CharacterSet.whitespacesAndNewlines
        func isWS(_ i: Int) -> Bool {
            guard let s = Unicode.Scalar(ns.character(at: i)) else { return false }
            return ws.contains(s)
        }
        // Eat trailing whitespace, then the word characters before the caret.
        while caret > 0, isWS(caret - 1) { caret -= 1 }
        while caret > 0, !isWS(caret - 1) { caret -= 1 }
        let start = caret
        let length = min(composerView.selectedRange().location, ns.length) - start
        guard length > 0 else { return }
        composerProgrammatic = true
        composerView.insertText("", replacementRange: NSRange(location: start, length: length))
        composerProgrammatic = false
        composerContentChanged()
    }

    func composerDeleteToStart() {
        composerProgrammatic = true
        let caret = composerView.selectedRange().location
        composerView.insertText("", replacementRange: NSRange(location: 0, length: caret))
        composerProgrammatic = false
        composerContentChanged()
    }

    func composerDeleteToEnd() {
        composerProgrammatic = true
        let ns = composerView.string as NSString
        let caret = composerView.selectedRange().location
        composerView.insertText("", replacementRange: NSRange(location: caret, length: ns.length - caret))
        composerProgrammatic = false
        composerContentChanged()
    }

    func composerClear() {
        composerProgrammatic = true
        composerView.string = ""
        composerProgrammatic = false
        composerContentChanged()
    }

    /// Replace the whole draft (transform previews, generated text), leaving
    /// the caret at the end so glide/ghost continue from there.
    func composerSetText(_ s: String) {
        composerProgrammatic = true
        composerView.string = s
        composerView.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
        composerProgrammatic = false
        composerContentChanged()
    }

    func composerContentChanged() {
        updateGhostLabel()
        updateComposerHeight()
        composerView.scrollRangeToVisible(composerView.selectedRange())
        needsDisplay = true
    }

    private func setupComposer() {
        composerView = ComposerTextView()
        composerView.isRichText = false
        composerView.font = NSFont.systemFont(ofSize: 14)
        composerView.textColor = .white
        composerView.drawsBackground = false
        composerView.insertionPointColor = NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
        composerView.isVerticallyResizable = true
        composerView.isHorizontallyResizable = false
        composerView.autoresizingMask = [.width]
        composerView.textContainerInset = NSSize(width: 4, height: 4)
        composerView.allowsUndo = true
        composerView.maxSize = NSSize(width: 10_000, height: 10_000)

        composerScroll = NSScrollView()
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.documentView = composerView
        addSubview(composerScroll)

        ghostLabel = NSTextField(labelWithString: "")
        let base = NSFont.systemFont(ofSize: 14)
        ghostLabel.font = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        ghostLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        ghostLabel.isHidden = true
        composerView.addSubview(ghostLabel)
        ghostLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self,
                                                                 action: #selector(ghostLabelClicked)))
        layoutComposer()
    }

    @objc private func ghostLabelClicked() {
        if let ghost { delegate?.keyboardView(self, didPickGhost: ghost) }
    }

    private func layoutComposer() {
        guard composerScroll != nil, let rect = ghostRect else { return }
        composerScroll.isHidden = !composerEnabled
        composerScroll.frame = CGRect(x: rect.minX + 4, y: rect.minY + 3,
                                      width: (chipsLeftEdge ?? rect.maxX) - rect.minX - 12,
                                      height: rect.height - 6)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutComposer()
    }

    /// Position the shaded AI continuation right after the last character,
    /// wrapping to the next line when there's no room.
    private func updateGhostLabel() {
        guard composerEnabled, let ghost,
              let lm = composerView.layoutManager, let tc = composerView.textContainer else {
            ghostLabel?.isHidden = true
            return
        }
        let glue = composerString.isEmpty || composerString.hasSuffix(" ") ? "" : " "
        ghostLabel.stringValue = glue + ghost
        ghostLabel.textColor = ghostSelected
            ? NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
            : NSColor(calibratedWhite: 0.5, alpha: 1)
        ghostLabel.sizeToFit()

        lm.ensureLayout(for: tc)
        let inset = composerView.textContainerInset
        var origin = CGPoint(x: inset.width + 2, y: inset.height)
        let ns = composerView.string as NSString
        if ns.length > 0 {
            let lastGlyph = lm.glyphIndexForCharacter(at: ns.length - 1)
            let lineRect = lm.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: tc)
            origin = CGPoint(x: lineRect.maxX + inset.width + 2, y: lineRect.minY + inset.height)
            let available = composerView.bounds.width - origin.x - 6
            if available < min(ghostLabel.frame.width, 70) {
                origin = CGPoint(x: inset.width + 2, y: lineRect.maxY + inset.height)
            }
        }
        ghostLabel.frame.origin = origin
        ghostLabel.isHidden = false
    }
    private var lastPreviewTime: TimeInterval = 0

    // Gesture state
    private var tracePoints: [CGPoint] = []
    private var tracking = false
    private var pressedKeyIndex: Int?
    private var hoverKeyIndex: Int?
    // Backspace press-and-hold auto-repeat.
    private var backspaceHoldTimer: Timer?
    private var backspaceHoldTicks = 0
    private var backspaceDidRepeat = false
    /// Candidate hovered while dragging a glide up into the suggestion row.
    private var hoverCandidateIndex: Int?
    /// Help legend overlay toggled by the "?" button.
    private var showHelp = false

    /// Whether the history panel is currently attached — drawn as an active state.
    var historyVisible = false {
        didSet { if oldValue != historyVisible { needsDisplay = true } }
    }

    /// Toolbar buttons, laid out with the shared uiScale so they stay legible
    /// at any keyboard size.
    private var toolbarButtonSize: CGSize { CGSize(width: 34 * uiScale, height: 22 * uiScale) }
    private var toolbarButtonY: CGFloat { (barHeight - toolbarButtonSize.height) / 2 }

    private var helpButtonRect: CGRect {
        let s = toolbarButtonSize
        return CGRect(x: bounds.width - KeyboardView.margin - s.width,
                      y: toolbarButtonY, width: s.width, height: s.height)
    }

    private var historyButtonRect: CGRect {
        let s = toolbarButtonSize
        return CGRect(x: helpButtonRect.minX - s.width - 6 * uiScale,
                      y: toolbarButtonY, width: s.width, height: s.height)
    }

    override var isFlipped: Bool { true }

    init(language: Language, scale: CGFloat = 1.0) {
        self.language = language
        self.layout = KeyboardLayout.build(for: language)
        self.unit = KeyboardView.baseUnit * scale
        let size = KeyboardView.preferredSize(for: self.layout, unit: self.unit)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        setupComposer()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func preferredSize(for layout: KeyboardLayout, unit: CGFloat) -> NSSize {
        NSSize(width: layout.unitColumns * unit + margin * 2,
               height: barHeight(unit: unit) + ghostHeight + predictionHeight + candidateHeight
                       + layout.unitRows * unit + margin)
    }

    func setLanguage(_ lang: Language) {
        language = lang
        layout = KeyboardLayout.build(for: lang)
        candidates = []
        predictions = []
        ghost = nil
        needsDisplay = true
    }

    // MARK: - Geometry helpers

    private var keysOriginY: CGFloat {
        barHeight + topRowHeight
            + KeyboardView.predictionHeight + KeyboardView.candidateHeight
    }

    /// Current full size, accounting for the dynamic composer height.
    func currentSize() -> NSSize {
        NSSize(width: layout.unitColumns * unit + KeyboardView.margin * 2,
               height: barHeight + topRowHeight + KeyboardView.predictionHeight
                       + KeyboardView.candidateHeight + layout.unitRows * unit + KeyboardView.margin)
    }

    private func updateComposerHeight() {
        // Never move the keys under the pointer mid-gesture.
        guard !tracking && !hoverTracing else { return }
        var target = KeyboardView.ghostHeight
        if composerEnabled, let lm = composerView?.layoutManager, let tc = composerView?.textContainer {
            lm.ensureLayout(for: tc)
            var contentHeight = lm.usedRect(for: tc).height
            if ghostLabel?.isHidden == false {
                contentHeight = max(contentHeight,
                                    ghostLabel.frame.maxY - composerView.textContainerInset.height)
            }
            target = min(max(KeyboardView.ghostHeight, contentHeight + 18), 100)
        }
        if abs(target - topRowHeight) > 0.5 {
            topRowHeight = target
            layoutComposer()
            delegate?.keyboardViewDidResize(self)
        } else {
            layoutComposer()
        }
    }

    func pixelFrame(for key: Key) -> CGRect {
        let u = unit
        let f = key.unitFrame
        return CGRect(x: KeyboardView.margin + f.minX * u + keyGap / 2,
                      y: keysOriginY + f.minY * u + keyGap / 2,
                      width: f.width * u - keyGap,
                      height: f.height * u - keyGap)
    }

    func keyIndex(at point: CGPoint) -> Int? {
        for (i, key) in layout.keys.enumerated() where pixelFrame(for: key).insetBy(dx: -keyGap / 2, dy: -keyGap / 2).contains(point) {
            return i
        }
        return nil
    }

    /// Centers of all letter keys in view coordinates — for the decoder.
    var letterCenters: [Character: CGPoint] {
        var out: [Character: CGPoint] = [:]
        for key in layout.keys {
            if let ch = key.letter {
                let f = pixelFrame(for: key)
                out[ch] = CGPoint(x: f.midX, y: f.midY)
            }
        }
        return out
    }

    private func rowRects(count: Int, y: CGFloat, height: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let totalW = bounds.width - KeyboardView.margin * 2
        let w = totalW / CGFloat(count)
        return (0..<count).map {
            CGRect(x: KeyboardView.margin + CGFloat($0) * w, y: y, width: w, height: height)
        }
    }

    /// Full-width top row: composer (with inline ghost) or the ghost chip.
    private var ghostRect: CGRect? {
        guard composerEnabled || ghost != nil else { return nil }
        return CGRect(x: KeyboardView.margin,
                      y: barHeight + 2,
                      width: bounds.width - KeyboardView.margin * 2,
                      height: topRowHeight - 4)
    }

    /// "Insert into app" chip at the right end of the composer row.
    private var insertChipRect: CGRect? {
        guard composerEnabled, let row = ghostRect else { return nil }
        // Without a text target the chip copies instead of inserting, so it is
        // pointless with an empty buffer.
        if !hasTextTarget && composerString.isEmpty { return nil }
        return CGRect(x: row.maxX - 40, y: row.minY + 3, width: 36, height: row.height - 6)
    }

    /// "✨ transform/instruction" chip, immediately left of the insert chip
    /// (or at the right end when the insert chip is hidden). Available on the
    /// board so the menu can be opened one-handed, without the ⌘⌥T shortcut.
    private var transformChipRect: CGRect? {
        guard composerEnabled, let row = ghostRect else { return nil }
        let rightEdge = insertChipRect?.minX ?? (row.maxX - 4)
        return CGRect(x: rightEdge - 36, y: row.minY + 3, width: 32, height: row.height - 6)
    }

    /// Leftmost edge of the trailing chips — where the text area must stop.
    private var chipsLeftEdge: CGFloat? {
        transformChipRect?.minX ?? insertChipRect?.minX
    }

    private var predictionRects: [CGRect] {
        rowRects(count: predictions.count,
                 y: barHeight + topRowHeight + 1,
                 height: KeyboardView.predictionHeight - 2)
    }

    private var candidateRects: [CGRect] {
        rowRects(count: candidates.count,
                 y: barHeight + topRowHeight
                    + KeyboardView.predictionHeight + 2,
                 height: KeyboardView.candidateHeight - 6)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // Mode switch (tap ↔ drag) in the handle strip.
        if modeButtonRect.insetBy(dx: -4, dy: -4).contains(p) && !showHelp {
            toggleInputMode()
            return
        }

        // Show/hide the typed-text history panel.
        if historyButtonRect.insetBy(dx: -3, dy: -4).contains(p) && !showHelp {
            delegate?.keyboardViewDidToggleHistory(self)
            return
        }

        // Help legend: the "?" button toggles it; any click closes it.
        if showHelp {
            showHelp = false
            needsDisplay = true
            return
        }
        if helpButtonRect.insetBy(dx: -4, dy: -4).contains(p) {
            showHelp = true
            needsDisplay = true
            return
        }

        // A tap while tracing commits the word — or picks the suggestion
        // it landed on.
        if hoverTracing {
            if let i = candidateRects.firstIndex(where: { $0.contains(p) }), i < candidates.count {
                hoverTracing = false
                tracePoints = []
                pressedKeyIndex = nil
                hoverKeyIndex = nil
                needsDisplay = true
                delegate?.keyboardView(self, didGlideSelect: i)
            } else {
                endTapTrace(typeLetterIfShort: true)
            }
            return
        }

        // Drag handle strip moves the window.
        if p.y < barHeight {
            window?.performDrag(with: event)
            return
        }

        // Composer row: transform chip, insert chip, or click to accept ghost.
        if let rect = ghostRect, rect.contains(p) {
            if let chip = transformChipRect, chip.insetBy(dx: -3, dy: -3).contains(p) {
                delegate?.keyboardViewDidRequestTransform(self)
            } else if let chip = insertChipRect, chip.insetBy(dx: -3, dy: -3).contains(p) {
                if !hasTextTarget {
                    // No field to inject into: copy the buffer to the clipboard.
                    delegate?.keyboardViewDidRequestCopy(self)
                } else {
                    // With composed text: insert it without submitting. With an
                    // empty buffer: submit a Return in the target app.
                    delegate?.keyboardView(self, didRequestInsert: composerString.isEmpty)
                }
            } else if let ghost {
                delegate?.keyboardView(self, didPickGhost: ghost)
            }
            return
        }
        for (i, rect) in predictionRects.enumerated() where rect.contains(p) {
            delegate?.keyboardView(self, didPickPrediction: i)
            return
        }
        for (i, rect) in candidateRects.enumerated() where rect.contains(p) {
            delegate?.keyboardView(self, didPickCandidate: i)
            return
        }

        tracking = true
        tracePoints = [p]
        pressedKeyIndex = keyIndex(at: p)
        hoverKeyIndex = pressedKeyIndex
        if let idx = pressedKeyIndex, layout.keys[idx].action == .backspace {
            startBackspaceHold()
        }
        needsDisplay = true
    }

    // MARK: - Backspace press-and-hold

    private func startBackspaceHold() {
        backspaceHoldTimer?.invalidate()
        backspaceHoldTicks = 0
        backspaceDidRepeat = false
        // First repeat fires after a deliberate hold; later ticks accelerate
        // and, past the per-character phase, delete whole words.
        scheduleBackspaceTick(after: 0.35)
    }

    private func scheduleBackspaceTick(after interval: TimeInterval) {
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.fireBackspaceRepeat()
        }
        // .common keeps it firing even while the mouse button is held down.
        RunLoop.main.add(t, forMode: .common)
        backspaceHoldTimer = t
    }

    private func fireBackspaceRepeat() {
        backspaceDidRepeat = true
        backspaceHoldTicks += 1
        // Switch from characters to words once the hold has been sustained.
        let byWord = backspaceHoldTicks > 9
        delegate?.keyboardView(self, didRepeatBackspaceByWord: byWord)
        // Accelerate: start slow, ramp toward a brisk steady cadence.
        let interval = max(0.05, 0.18 - Double(backspaceHoldTicks) * 0.012)
        scheduleBackspaceTick(after: interval)
    }

    private func stopBackspaceHold() {
        backspaceHoldTimer?.invalidate()
        backspaceHoldTimer = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        let p = convert(event.locationInWindow, from: nil)

        if p.y < keysOriginY {
            // Pointer is up in the suggestion rows: freeze the trace and
            // highlight the candidate under the pointer for drag-to-select.
            hoverKeyIndex = nil
            hoverCandidateIndex = candidateRects.firstIndex { $0.insetBy(dx: 0, dy: -4).contains(p) }
            needsDisplay = true
            return
        }

        hoverCandidateIndex = nil
        tracePoints.append(p)
        hoverKeyIndex = keyIndex(at: p)

        // If the finger slides off the backspace key, cancel the auto-repeat.
        if backspaceHoldTimer != nil,
           hoverKeyIndex.map({ layout.keys[$0].action }) != .backspace {
            stopBackspaceHold()
        }

        // Throttled live preview of the word being formed.
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastPreviewTime > 0.14,
           let idx = pressedKeyIndex, layout.keys[idx].isLetter {
            lastPreviewTime = now
            delegate?.keyboardView(self, didUpdateGlide: tracePoints)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        tracking = false
        stopBackspaceHold()
        // The hold already deleted plenty — don't also emit a tap-delete.
        if backspaceDidRepeat {
            backspaceDidRepeat = false
            pressedKeyIndex = nil
            hoverKeyIndex = nil
            needsDisplay = true
            return
        }
        defer {
            // Keep the trace alive if this tap just started tap-toggle gliding.
            if !hoverTracing {
                tracePoints = []
                pressedKeyIndex = nil
                hoverKeyIndex = nil
            }
            hoverCandidateIndex = nil
            needsDisplay = true
        }

        // Released on top of a suggestion: that word wins over the decoder.
        if let idx = hoverCandidateIndex, idx < candidates.count {
            delegate?.keyboardView(self, didGlideSelect: idx)
            return
        }

        let pathLen = GestureDecoder.pathLength(tracePoints)
        let isTap = pathLen < unit * 0.45

        if isTap {
            if let idx = pressedKeyIndex {
                let key = layout.keys[idx]
                if hoverGlideEnabled && key.isLetter {
                    // Drag mode: a soft tap starts gliding without holding.
                    startTapTrace(at: convert(event.locationInWindow, from: nil), keyIndex: idx)
                } else {
                    delegate?.keyboardView(self, didTap: key)
                }
            }
        } else if let idx = pressedKeyIndex, layout.keys[idx].isLetter {
            delegate?.keyboardView(self, didGlide: tracePoints)
        }
    }

    // MARK: - Tap-toggle glide (no holding needed)
    // A soft tap on a letter starts the trace; move the pointer freely
    // (no button held); another tap commits the word. A tap-tap with no
    // movement in between types the letter, so tap-typing still works.

    var hoverGlideEnabled = true
    private var hoverTracing = false

    private var modeButtonRect: CGRect {
        let s = toolbarButtonSize
        return CGRect(x: KeyboardView.margin, y: toolbarButtonY, width: s.width, height: s.height)
    }

    private func toggleInputMode() {
        if hoverTracing { endTapTrace(typeLetterIfShort: false) }
        hoverGlideEnabled.toggle()
        flash(hoverGlideEnabled ? "∿ arrastre" : "● pulsación")
        delegate?.keyboardView(self, didSetHoverGlide: hoverGlideEnabled)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hoverTracing { endTapTrace(typeLetterIfShort: false) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard hoverTracing else { return }
        if p.y >= keysOriginY {
            tracePoints.append(p)
            hoverKeyIndex = keyIndex(at: p)
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastPreviewTime > 0.14 {
                lastPreviewTime = now
                delegate?.keyboardView(self, didUpdateGlide: tracePoints)
            }
        }
        needsDisplay = true
    }

    private func startTapTrace(at p: CGPoint, keyIndex idx: Int) {
        hoverTracing = true
        tracePoints = [p]
        pressedKeyIndex = idx
        hoverKeyIndex = idx
        needsDisplay = true
    }

    private func endTapTrace(typeLetterIfShort: Bool) {
        hoverTracing = false
        let points = tracePoints
        let pressed = pressedKeyIndex
        tracePoints = []
        pressedKeyIndex = nil
        hoverKeyIndex = nil
        needsDisplay = true
        let length = GestureDecoder.pathLength(points)
        if length < unit * 0.45 {
            // tap-tap without movement: the user wanted that letter.
            if typeLetterIfShort, let pressed {
                delegate?.keyboardView(self, didTap: layout.keys[pressed])
            }
        } else {
            delegate?.keyboardView(self, didGlide: points)
        }
    }

    // MARK: - Two-finger swipes (trackpad) — gesture shortcuts

    private var swipeAccum = CGVector.zero
    private var swipeActive = false
    private var swipePath: [CGPoint] = []

    // Swipe-up selection mode: keep fingers down, move to choose, lift to accept.
    private var swipeSelecting = false
    /// -1 = nothing selected (lift does nothing); 0 candidates, 1 predictions, 2 ghost.
    private var selRow = -1
    private var selIndex = 0
    private var selAccumX: CGFloat = 0
    private var selAccumY: CGFloat = 0
    private(set) var selectedPredictionIndex: Int?
    private(set) var ghostSelected = false

    override func scrollWheel(with event: NSEvent) {
        // Normalize deltas to finger direction regardless of "natural scrolling".
        let factor: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        if event.phase == .began {
            swipeAccum = .zero
            swipePath = [.zero]
            swipeActive = true
        }
        if swipeActive, event.phase == .changed {
            swipeAccum.dx += event.scrollingDeltaX * factor
            swipeAccum.dy += event.scrollingDeltaY * factor
            swipePath.append(CGPoint(x: swipeAccum.dx, y: swipeAccum.dy))

            if swipeSelecting {
                selAccumX += event.scrollingDeltaX * factor
                selAccumY += -event.scrollingDeltaY * factor // fingers up = positive
                stepSwipeSelection()
            } else {
                // A clear upward movement enters selection mode.
                let fingerY = -swipeAccum.dy
                if fingerY > 38 && abs(swipeAccum.dx) < fingerY {
                    enterSwipeSelection()
                }
            }
        }
        if event.phase == .ended {
            swipeActive = false
            let wasSelecting = swipeSelecting
            let row = selRow, index = selIndex
            clearSwipeSelection()
            if isCircularStroke(swipePath) {
                toggleInputMode()
            } else if wasSelecting {
                acceptSwipeSelection(row: row, index: index)
            } else {
                classifySwipe(swipeAccum)
            }
        }
        // Legacy mouse wheel (no gesture phases): each notch is a vertical swipe.
        if event.phase == [] && event.momentumPhase == [] {
            classifySwipe(CGVector(dx: 0, dy: event.scrollingDeltaY * factor * 12))
        }
    }

    // MARK: Swipe selection helpers

    private var rowCounts: [Int] {
        [candidates.count, predictions.count, ghost != nil ? 1 : 0]
    }

    private func enterSwipeSelection() {
        let counts = rowCounts
        guard let firstRow = counts.firstIndex(where: { $0 > 0 }) else { return }
        swipeSelecting = true
        selRow = firstRow
        selIndex = 0
        selAccumX = 0
        selAccumY = 0
        updateSelectionHighlight()
    }

    private func stepSwipeSelection() {
        let counts = rowCounts
        // Horizontal: move within the row.
        while selAccumX > 60 {
            selAccumX -= 60
            if selRow >= 0 { selIndex = min(selIndex + 1, max(0, counts[selRow] - 1)) }
        }
        while selAccumX < -60 {
            selAccumX += 60
            selIndex = max(0, selIndex - 1)
        }
        // Vertical: move between rows (up = candidates → predictions → ghost).
        while selAccumY > 55 {
            selAccumY -= 55
            var next = selRow + 1
            while next <= 2 && counts[next] == 0 { next += 1 }
            if next <= 2 { selRow = next; selIndex = min(selIndex, counts[next] - 1) }
        }
        while selAccumY < -55 {
            selAccumY += 55
            var next = selRow - 1
            while next >= 0 && counts[next] == 0 { next -= 1 }
            if next >= 0 {
                selRow = next
                selIndex = min(selIndex, counts[next] - 1)
            } else {
                selRow = -1 // moved below the rows: deselect, lift cancels
            }
        }
        updateSelectionHighlight()
    }

    private func updateSelectionHighlight() {
        hoverCandidateIndex = selRow == 0 ? selIndex : nil
        selectedPredictionIndex = selRow == 1 ? selIndex : nil
        ghostSelected = selRow == 2
        updateGhostLabel() // tint the inline ghost when selected
        needsDisplay = true
    }

    private func clearSwipeSelection() {
        swipeSelecting = false
        selRow = -1
        hoverCandidateIndex = nil
        selectedPredictionIndex = nil
        ghostSelected = false
        updateGhostLabel()
        needsDisplay = true
    }

    private func acceptSwipeSelection(row: Int, index: Int) {
        switch row {
        case 0 where index < candidates.count:
            flash("✓")
            if hoverTracing {
                resetTraceState()
                delegate?.keyboardView(self, didGlideSelect: index)
            } else {
                delegate?.keyboardView(self, didPickCandidate: index)
            }
        case 1 where index < predictions.count:
            flash("✓")
            delegate?.keyboardView(self, didPickPrediction: index)
        case 2:
            if let ghost {
                flash("✦")
                if hoverTracing { resetTraceState() }
                delegate?.keyboardView(self, didPickGhost: ghost)
            }
        default:
            break // deselected: lifting accepts nothing
        }
    }

    /// A circular two-finger stroke: lots of travel, little net displacement,
    /// and the direction of motion rotates most of a full turn.
    private func isCircularStroke(_ path: [CGPoint]) -> Bool {
        guard path.count >= 8 else { return false }
        // Direction samples from segments long enough to be meaningful.
        var directions: [CGFloat] = []
        var prev = path[0]
        var pathLength: CGFloat = 0
        for p in path.dropFirst() {
            let dx = p.x - prev.x, dy = p.y - prev.y
            let seg = hypot(dx, dy)
            pathLength += seg
            if seg > 3 {
                directions.append(atan2(dy, dx))
                prev = p
            }
        }
        guard directions.count >= 6, pathLength > 90 else { return false }
        let net = hypot(path.last!.x, path.last!.y)
        guard net < pathLength * 0.45 else { return false }
        // Accumulated signed turning angle.
        var winding: CGFloat = 0
        for i in 1..<directions.count {
            var d = directions[i] - directions[i - 1]
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            winding += d
        }
        return abs(winding) > 4.4 // ~250° of rotation
    }

    func classifySwipe(_ v: CGVector) {
        let magnitude = hypot(v.dx, v.dy)
        guard magnitude > 24 else { return }
        // Short vs long flick: a long upward flick accepts the whole ghost,
        // a short one just its first word (partial acceptance).
        let long = magnitude > 90
        // Vertical axis empirically calibrated: scroll deltas report the
        // opposite sign of the finger motion on this setup.
        let fingerY = -v.dy
        // Cardinal directions only — the dominant axis wins, no dead zones.
        let direction: FlickDirection = abs(v.dx) > abs(fingerY)
            ? (v.dx > 0 ? .right : .left)
            : (fingerY > 0 ? .up : .down)

        // While a trace is in progress the swipe applies to THAT word,
        // never to the previously inserted one.
        if hoverTracing {
            switch direction {
            case .up:
                guard !candidates.isEmpty else { return }
                resetTraceState()
                flash("✓")
                delegate?.keyboardView(self, didGlideSelect: 0)
                return
            case .left:
                // Cancel the in-progress word without typing anything.
                resetTraceState()
                flash("✕")
                return
            case .right, .down:
                // Commit the word first, then apply the action.
                endTapTrace(typeLetterIfShort: false)
            }
        }
        delegate?.keyboardView(self, didFlick: direction, long: long)
    }

    private func resetTraceState() {
        hoverTracing = false
        tracePoints = []
        pressedKeyIndex = nil
        hoverKeyIndex = nil
        needsDisplay = true
    }

    // MARK: - Right-click menu: editing actions

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let actions = EditAction.allCases
        for (i, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
            if action == .selectAllCopy { menu.addItem(.separator()) }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        let actions = EditAction.allCases
        guard sender.tag < actions.count else { return }
        delegate?.keyboardView(self, didEdit: actions[sender.tag])
    }

    // MARK: - Gesture feedback flash

    private var flashSymbol: String?
    private var flashClearWork: DispatchWorkItem?

    /// Briefly flash a big symbol over the keys to confirm a gesture fired.
    func flash(_ symbol: String) {
        flashSymbol = symbol
        needsDisplay = true
        flashClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flashSymbol = nil
            self?.needsDisplay = true
        }
        flashClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(calibratedWhite: 0.13, alpha: 0.97)
        bg.setFill()
        let panel = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        panel.fill()

        // Drag handle, centered in the toolbar strip.
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        let handle = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 26, y: (barHeight - 5) / 2,
                                                      width: 52, height: 5),
                                  xRadius: 2.5, yRadius: 2.5)
        handle.fill()

        drawCandidates()

        for (i, key) in layout.keys.enumerated() {
            drawKey(key, highlighted: i == hoverKeyIndex)
        }

        drawTrace()

        if let flashSymbol {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: flashSymbol.count > 2 ? 30 : 52, weight: .bold),
                .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 0.85)
            ]
            let s = NSAttributedString(string: flashSymbol, attributes: attrs)
            let size = s.size()
            let keysMidY = keysOriginY + (bounds.height - keysOriginY) / 2
            s.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: keysMidY - size.height / 2))
        }

        drawHelpButton()
        drawHistoryButton()
        drawModeButton()
        if showHelp { drawHelpOverlay() }
    }

    /// Shared pill style for the toolbar-strip buttons.
    private func drawToolbarButton(in rect: CGRect, symbol: String, active: Bool) {
        if active {
            NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.5, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        }
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * uiScale, weight: .semibold),
            .foregroundColor: active
                ? NSColor(calibratedRed: 0.75, green: 0.87, blue: 1.0, alpha: 1)
                : NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
        ]
        let s = NSAttributedString(string: symbol, attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawModeButton() {
        drawToolbarButton(in: modeButtonRect, symbol: hoverGlideEnabled ? "∿" : "●", active: false)
    }

    private func drawHistoryButton() {
        drawToolbarButton(in: historyButtonRect, symbol: "⟲", active: historyVisible)
    }

    private func drawHelpButton() {
        drawToolbarButton(in: helpButtonRect, symbol: "?", active: showHelp)
    }

    private func drawHelpOverlay() {
        let area = CGRect(x: KeyboardView.margin, y: barHeight + 2,
                          width: bounds.width - KeyboardView.margin * 2,
                          height: bounds.height - barHeight - KeyboardView.margin)
        NSColor(calibratedWhite: 0.1, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: area, xRadius: 12, yRadius: 12).fill()

        // Title
        let title = NSAttributedString(string: "Acciones rápidas — desliza 2 dedos",
                                       attributes: [
                                           .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                                           .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
                                       ])
        title.draw(at: CGPoint(x: area.midX - title.size().width / 2, y: area.minY + 10))

        // Compass: the four swipe directions around a center dot.
        // Screen coords (flipped view): -y is up.
        let center = CGPoint(x: area.midX, y: area.midY - 4)
        let rx = area.width * 0.30
        let ry = area.height * 0.26
        let items: [(arrow: String, label: String, dx: CGFloat, dy: CGFloat)] = [
            ("→", "punto", 1, 0),
            ("←", "borrar", -1, 0),
            ("↑", "elegir sugerencia (sin soltar)", 0, -1),
            ("↓", "espacio", 0, 1)
        ]

        // Center pad
        NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)).fill()

        for item in items {
            let pos = CGPoint(x: center.x + item.dx * rx, y: center.y + item.dy * ry)
            let arrow = NSAttributedString(string: item.arrow, attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
            ])
            let aSize = arrow.size()
            arrow.draw(at: CGPoint(x: pos.x - aSize.width / 2, y: pos.y - aSize.height / 2 - 9))

            let label = NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
            ])
            let lSize = label.size()
            label.draw(at: CGPoint(x: pos.x - lSize.width / 2, y: pos.y + 9))
        }

        // Hints at the bottom.
        let circleHint = NSAttributedString(string: "⟳ trazo circular: cambiar modo ● pulsación / ∿ arrastre",
                                            attributes: [
                                                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
                                            ])
        circleHint.draw(at: CGPoint(x: area.midX - circleHint.size().width / 2, y: area.maxY - 42))
        let hint = NSAttributedString(string: "clic derecho: pegar · copiar todo · borrar hasta el final / principio · borrar todo",
                                      attributes: [
                                          .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                          .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)
                                      ])
        hint.draw(at: CGPoint(x: area.midX - hint.size().width / 2, y: area.maxY - 24))
    }

    private func drawCandidates() {
        // Top row: composer with inline shaded ghost, or the classic ghost chip.
        let base = NSFont.systemFont(ofSize: 13, weight: .regular)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        if composerEnabled, let rect = ghostRect {
            drawComposer(in: rect, italic: italic)
        } else if let ghost, let rect = ghostRect {
            NSColor(calibratedRed: 0.35, green: 0.6, blue: 1.0, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
            ]
            let s = NSAttributedString(string: "✦ " + ghost, attributes: attrs)
            var size = s.size()
            size.width = min(size.width, rect.width - 16)
            s.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
        }

        // Prediction row: AI word suggestions, italic gray.
        for (i, rect) in predictionRects.enumerated() {
            if i == selectedPredictionIndex {
                NSColor(calibratedRed: 0.25, green: 0.5, blue: 1.0, alpha: 0.8).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: italic,
                .foregroundColor: i == selectedPredictionIndex
                    ? NSColor.white
                    : NSColor(calibratedWhite: 0.65, alpha: 1)
            ]
            let s = NSAttributedString(string: predictions[i], attributes: attrs)
            let size = s.size()
            s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            if i > 0 {
                NSColor(calibratedWhite: 0.26, alpha: 1).setFill()
                NSRect(x: rect.minX, y: rect.minY + 5, width: 1, height: rect.height - 10).fill()
            }
        }
        if !predictions.isEmpty || !candidates.isEmpty {
            NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
            NSRect(x: KeyboardView.margin,
                   y: barHeight + topRowHeight + KeyboardView.predictionHeight,
                   width: bounds.width - KeyboardView.margin * 2, height: 1).fill()
        }

        // Alternatives for the last word: bigger, first one highlighted.
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        for (i, rect) in candidateRects.enumerated() {
            if i == hoverCandidateIndex {
                NSColor(calibratedRed: 0.25, green: 0.5, blue: 1.0, alpha: 0.8).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 0), xRadius: 8, yRadius: 8).fill()
            } else if i == 0 {
                NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.95, alpha: 0.35).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 0), xRadius: 8, yRadius: 8).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: i == 0 || i == hoverCandidateIndex
                    ? NSColor.white : NSColor(calibratedWhite: 0.8, alpha: 1)
            ]
            let s = NSAttributedString(string: candidates[i], attributes: attrs)
            let size = s.size()
            s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            if i > 0 {
                NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
                NSRect(x: rect.minX, y: rect.minY + 6, width: 1, height: rect.height - 12).fill()
            }
        }
    }

    /// The composer: an inset "input" showing the buffer, a caret, the AI
    /// continuation shaded inline, and the ↪ insert chip.
    private func drawComposer(in rect: CGRect, italic: NSFont) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        if ghostSelected {
            NSColor(calibratedRed: 0.25, green: 0.5, blue: 1.0, alpha: 0.9).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            border.lineWidth = 2
            border.stroke()
        }

        let chip = insertChipRect
        let textArea = CGRect(x: rect.minX + 10, y: rect.minY,
                              width: (chipsLeftEdge ?? rect.maxX) - rect.minX - 16,
                              height: rect.height)

        // The text itself lives in the embedded NSTextView; draw only the
        // placeholder when everything is empty.
        if composerString.isEmpty && ghost == nil {
            let placeholder = NSAttributedString(string: "escribe aquí…", attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(calibratedWhite: 0.4, alpha: 1)
            ])
            placeholder.draw(at: CGPoint(x: textArea.minX + 2, y: rect.midY - placeholder.size().height / 2))
        }

        if let chip {
            let copyMode = !hasTextTarget
            let tint = copyMode
                ? NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.4, alpha: 0.6)
                : NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.95, alpha: 0.5)
            tint.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            let glyph = NSAttributedString(string: copyMode ? "⧉" : "↪", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            let gSize = glyph.size()
            glyph.draw(at: CGPoint(x: chip.midX - gSize.width / 2, y: chip.midY - gSize.height / 2))
        }

        if let transformChip = transformChipRect {
            NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.85, alpha: 0.5).setFill()
            NSBezierPath(roundedRect: transformChip, xRadius: 6, yRadius: 6).fill()
            let glyph = NSAttributedString(string: "✨", attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.white
            ])
            let gSize = glyph.size()
            glyph.draw(at: CGPoint(x: transformChip.midX - gSize.width / 2,
                                   y: transformChip.midY - gSize.height / 2))
        }
    }

    private func drawKey(_ key: Key, highlighted: Bool) {
        let rect = pixelFrame(for: key)
        // Character keys (letters, digits, punctuation) share the light style.
        let isSpecial: Bool
        if case .char = key.action { isSpecial = false } else { isSpecial = true }
        var fill = isSpecial
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.30, alpha: 1)
        if highlighted {
            fill = NSColor(calibratedRed: 0.25, green: 0.5, blue: 1.0, alpha: 1)
        }
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()

        let fontSize: CGFloat = key.isLetter ? 20 : 14
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: key.isLetter ? .regular : .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: key.label, attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawTrace() {
        guard tracePoints.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: tracePoints[0])
        for p in tracePoints.dropFirst() { path.line(to: p) }
        path.lineWidth = 9
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.55).setStroke()
        path.stroke()
    }
}
