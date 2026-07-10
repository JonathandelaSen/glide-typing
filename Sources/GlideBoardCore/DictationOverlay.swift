import AppKit

@MainActor
final class DictationOverlay {
    enum Phase {
        case preparing
        case recording
        case transcribing
        case inserting
        case failed(String)
    }

    private let panel: NSPanel
    private let view: DictationOverlayView
    private var dismissWork: DispatchWorkItem?

    init() {
        view = DictationOverlayView(frame: NSRect(x: 0, y: 0, width: 330, height: 76))
        panel = NSPanel(contentRect: view.bounds,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
    }

    func show(_ phase: Phase, destination: String) {
        dismissWork?.cancel()
        view.phase = phase
        view.destination = destination
        position()
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                     y: frame.minY + 26))
    }
}

private final class DictationOverlayView: NSView {
    var phase: DictationOverlay.Phase = .preparing { didSet { refresh() } }
    var destination = "GlideBoard" { didSet { refresh() } }
    private var startedAt = Date()
    private var tick = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
            self?.tick += 1
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func refresh() {
        if case .preparing = phase { startedAt = Date() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 15, yRadius: 15).fill()

        drawSignal()
        let (title, subtitle) = labels()
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)
        ]
        NSAttributedString(string: title, attributes: titleAttributes)
            .draw(at: NSPoint(x: 74, y: 39))
        NSAttributedString(string: subtitle, attributes: subtitleAttributes)
            .draw(at: NSPoint(x: 74, y: 20))
    }

    private func labels() -> (String, String) {
        switch phase {
        case .preparing:
            return ("Preparando micrófono", "Destino: \(destination)")
        case .recording:
            return ("Grabando en \(destination)", "Suelta el atajo para terminar")
        case .transcribing:
            return ("Transcribiendo audio", "Audio de \(durationText()) · sigue procesando")
        case .inserting:
            return ("Insertando en \(destination)", "El texto anterior se conserva")
        case .failed(let message):
            return ("No se pudo iniciar el dictado", message)
        }
    }

    private func durationText() -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func drawSignal() {
        let color: NSColor
        switch phase {
        case .recording: color = NSColor(calibratedRed: 0.96, green: 0.30, blue: 0.33, alpha: 1)
        case .failed: color = NSColor(calibratedRed: 0.96, green: 0.48, blue: 0.42, alpha: 1)
        default: color = NSColor(calibratedRed: 0.40, green: 0.67, blue: 1.0, alpha: 1)
        }
        for index in 0..<5 {
            let pulse = (tick + index * 2) % 6
            let height = 13 + CGFloat(pulse <= 3 ? pulse : 6 - pulse) * 7
            let rect = CGRect(x: 25 + CGFloat(index) * 8, y: bounds.midY - height / 2,
                              width: 4, height: height)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
