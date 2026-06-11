import AppKit

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didTap key: Key)
    func keyboardView(_ view: KeyboardView, didGlide points: [CGPoint])
    func keyboardView(_ view: KeyboardView, didUpdateGlide points: [CGPoint])
    func keyboardView(_ view: KeyboardView, didPickCandidate index: Int)
    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int)
}

final class KeyboardView: NSView {
    weak var delegate: KeyboardViewDelegate?

    // Geometry
    static let baseUnit: CGFloat = 56
    let unit: CGFloat
    static let margin: CGFloat = 10
    static let handleHeight: CGFloat = 16
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
    private var lastPreviewTime: TimeInterval = 0

    // Gesture state
    private var tracePoints: [CGPoint] = []
    private var tracking = false
    private var pressedKeyIndex: Int?
    private var hoverKeyIndex: Int?

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
               height: handleHeight + predictionHeight + candidateHeight + layout.unitRows * unit + margin)
    }

    func setLanguage(_ lang: Language) {
        language = lang
        layout = KeyboardLayout.build(for: lang)
        candidates = []
        predictions = []
        needsDisplay = true
    }

    // MARK: - Geometry helpers

    private var keysOriginY: CGFloat {
        KeyboardView.handleHeight + KeyboardView.predictionHeight + KeyboardView.candidateHeight
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

    private var predictionRects: [CGRect] {
        rowRects(count: predictions.count,
                 y: KeyboardView.handleHeight + 1,
                 height: KeyboardView.predictionHeight - 2)
    }

    private var candidateRects: [CGRect] {
        rowRects(count: candidates.count,
                 y: KeyboardView.handleHeight + KeyboardView.predictionHeight + 2,
                 height: KeyboardView.candidateHeight - 6)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // Drag handle strip moves the window.
        if p.y < KeyboardView.handleHeight {
            window?.performDrag(with: event)
            return
        }

        // Prediction row (phrase continuation), then candidate row.
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
            tracePoints = []
            pressedKeyIndex = nil
            hoverKeyIndex = nil
            needsDisplay = true
        }

        let pathLen = GestureDecoder.pathLength(tracePoints)
        let isTap = pathLen < unit * 0.45

        if isTap {
            if let idx = pressedKeyIndex {
                delegate?.keyboardView(self, didTap: layout.keys[idx])
            }
        } else if let idx = pressedKeyIndex, layout.keys[idx].isLetter {
            delegate?.keyboardView(self, didGlide: tracePoints)
        }
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
    }

    private func drawCandidates() {
        // Next-word predictions: italic, gray, their own row at the top.
        let base = NSFont.systemFont(ofSize: 13, weight: .regular)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
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
                   y: KeyboardView.handleHeight + KeyboardView.predictionHeight,
                   width: bounds.width - KeyboardView.margin * 2, height: 1).fill()
        }

        // Alternatives for the last word: bigger, first one highlighted.
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        for (i, rect) in candidateRects.enumerated() {
            if i == 0 {
                NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.95, alpha: 0.35).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 0), xRadius: 8, yRadius: 8).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: i == 0 ? NSColor.white : NSColor(calibratedWhite: 0.8, alpha: 1)
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
        let isSpecial = !key.isLetter && key.action != .char(",") && key.action != .char(".")
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
