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
    /// A two-finger swipe shortcut over the keyboard.
    func keyboardView(_ view: KeyboardView, didFlick direction: FlickDirection)
    /// An editing action chosen from the right-click menu.
    func keyboardView(_ view: KeyboardView, didEdit action: EditAction)
    /// The user toggled between tap mode and drag (no-click glide) mode.
    func keyboardView(_ view: KeyboardView, didSetHoverGlide enabled: Bool)
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
    static let handleHeight: CGFloat = 16
    static let ghostHeight: CGFloat = 32
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
    /// AI phrase completion (ghost text), shown first in the prediction row.
    var ghost: String? {
        didSet { needsDisplay = true }
    }
    private var lastPreviewTime: TimeInterval = 0

    // Gesture state
    private var tracePoints: [CGPoint] = []
    private var tracking = false
    private var pressedKeyIndex: Int?
    private var hoverKeyIndex: Int?
    /// Candidate hovered while dragging a glide up into the suggestion row.
    private var hoverCandidateIndex: Int?
    /// Help legend overlay toggled by the "?" button.
    private var showHelp = false

    private var helpButtonRect: CGRect {
        CGRect(x: bounds.width - 26, y: 3, width: 16, height: 16)
    }

    override var isFlipped: Bool { true }

    init(language: Language, scale: CGFloat = 1.0) {
        self.language = language
        self.layout = KeyboardLayout.build(for: language)
        self.unit = KeyboardView.baseUnit * scale
        let size = KeyboardView.preferredSize(for: self.layout, unit: self.unit)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    static func preferredSize(for layout: KeyboardLayout, unit: CGFloat) -> NSSize {
        NSSize(width: layout.unitColumns * unit + margin * 2,
               height: handleHeight + ghostHeight + predictionHeight + candidateHeight
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
        KeyboardView.handleHeight + KeyboardView.ghostHeight
            + KeyboardView.predictionHeight + KeyboardView.candidateHeight
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

    /// Full-width click target for the AI phrase completion.
    private var ghostRect: CGRect? {
        guard ghost != nil else { return nil }
        return CGRect(x: KeyboardView.margin,
                      y: KeyboardView.handleHeight + 2,
                      width: bounds.width - KeyboardView.margin * 2,
                      height: KeyboardView.ghostHeight - 4)
    }

    private var predictionRects: [CGRect] {
        rowRects(count: predictions.count,
                 y: KeyboardView.handleHeight + KeyboardView.ghostHeight + 1,
                 height: KeyboardView.predictionHeight - 2)
    }

    private var candidateRects: [CGRect] {
        rowRects(count: candidates.count,
                 y: KeyboardView.handleHeight + KeyboardView.ghostHeight
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
        if p.y < KeyboardView.handleHeight {
            window?.performDrag(with: event)
            return
        }

        // Ghost row, then prediction row, then candidate row.
        if let ghost, let rect = ghostRect, rect.contains(p) {
            delegate?.keyboardView(self, didPickGhost: ghost)
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
        needsDisplay = true
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

        // Throttled live preview of the word being formed.
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastPreviewTime > 0.09,
           let idx = pressedKeyIndex, layout.keys[idx].isLetter {
            lastPreviewTime = now
            delegate?.keyboardView(self, didUpdateGlide: tracePoints)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        tracking = false
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
        CGRect(x: 10, y: 2, width: 34, height: 16)
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
            if now - lastPreviewTime > 0.09 {
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

    override func scrollWheel(with event: NSEvent) {
        // Normalize deltas to finger direction regardless of "natural scrolling".
        let factor: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        if event.phase == .began {
            swipeAccum = .zero
            swipeActive = true
        }
        if swipeActive, event.phase == .changed {
            swipeAccum.dx += event.scrollingDeltaX * factor
            swipeAccum.dy += event.scrollingDeltaY * factor
        }
        if event.phase == .ended {
            swipeActive = false
            classifySwipe(swipeAccum)
        }
        // Legacy mouse wheel (no gesture phases): each notch is a vertical swipe.
        if event.phase == [] && event.momentumPhase == [] {
            classifySwipe(CGVector(dx: 0, dy: event.scrollingDeltaY * factor * 12))
        }
    }

    private func classifySwipe(_ v: CGVector) {
        guard hypot(v.dx, v.dy) > 24 else { return }
        // Vertical axis empirically calibrated: scroll deltas report the
        // opposite sign of the finger motion on this setup.
        let fingerY = -v.dy
        // Cardinal directions only — the dominant axis wins, no dead zones.
        let direction: FlickDirection = abs(v.dx) > abs(fingerY)
            ? (v.dx > 0 ? .right : .left)
            : (fingerY > 0 ? .up : .down)
        delegate?.keyboardView(self, didFlick: direction)
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

        // Drag handle
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        let handle = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 26, y: 6, width: 52, height: 5),
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
        drawModeButton()
        if showHelp { drawHelpOverlay() }
    }

    private func drawModeButton() {
        let rect = modeButtonRect
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.78, blue: 1.0, alpha: 1)
        ]
        let s = NSAttributedString(string: hoverGlideEnabled ? "∿" : "●", attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawHelpButton() {
        let rect = helpButtonRect
        NSColor(calibratedWhite: showHelp ? 0.55 : 0.35, alpha: 1).setStroke()
        let circle = NSBezierPath(ovalIn: rect)
        circle.lineWidth = 1.2
        circle.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: showHelp ? 0.8 : 0.5, alpha: 1)
        ]
        let s = NSAttributedString(string: "?", attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawHelpOverlay() {
        let area = CGRect(x: KeyboardView.margin, y: KeyboardView.handleHeight + 2,
                          width: bounds.width - KeyboardView.margin * 2,
                          height: bounds.height - KeyboardView.handleHeight - KeyboardView.margin)
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
            ("→", "espacio", 1, 0),
            ("←", "borrar", -1, 0),
            ("↑", "aceptar ✦", 0, -1),
            ("↓", "punto", 0, 1)
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

        // Right-click hint at the bottom.
        let hint = NSAttributedString(string: "clic derecho: pegar · copiar todo · borrar hasta el final / principio · borrar todo",
                                      attributes: [
                                          .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                          .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)
                                      ])
        hint.draw(at: CGPoint(x: area.midX - hint.size().width / 2, y: area.maxY - 24))
    }

    private func drawCandidates() {
        // Ghost row: the AI phrase completion as a full-width chip.
        let base = NSFont.systemFont(ofSize: 13, weight: .regular)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        if let ghost, let rect = ghostRect {
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

        // Prediction row: bigram next words, italic gray.
        for (i, rect) in predictionRects.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: italic,
                .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1)
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
                   y: KeyboardView.handleHeight + KeyboardView.ghostHeight + KeyboardView.predictionHeight,
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

    private func drawKey(_ key: Key, highlighted: Bool) {
        let rect = pixelFrame(for: key)
        let punctuation: [KeyAction] = [.char(","), .char("."), .char("?"), .char("!")]
        let isSpecial = !key.isLetter && !punctuation.contains(key.action)
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
