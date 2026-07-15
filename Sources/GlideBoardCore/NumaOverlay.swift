import AppKit

@MainActor
final class NumaOverlay {
    enum Phase {
        case attending(String)
        case commandRecognized(String)
        case preparing
        case recording
        case transcribing
        case inserting
        case notUnderstood
        case failed(String)
    }

    private let panel: NSPanel
    private let view: NumaOverlayView
    private var dismissWork: DispatchWorkItem?
    private let screenProvider: () -> NSScreen?

    init(screenProvider: @escaping () -> NSScreen? = { NSScreen.main }) {
        self.screenProvider = screenProvider
        view = NumaOverlayView(frame: NSRect(x: 0, y: 0, width: 330, height: 76))
        panel = NSPanel(contentRect: view.bounds,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
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

    func updateRMS(_ rms: Float) { view.updateRMS(rms) }

    private func position() {
        guard let screen = screenProvider() else { return }
        panel.setFrameOrigin(OverlayPositioner.origin(
            visibleFrame: screen.visibleFrame, panelSize: panel.frame.size))
    }
}

private final class NumaOverlayView: NSView {
    var phase: NumaOverlay.Phase = .preparing { didSet { refresh() } }
    var destination = "Numa" { didSet { refresh() } }
    private var startedAt = Date()
    private var signalLevel: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
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

    func updateRMS(_ rms: Float) {
        let normalized = NumaSignalLevel.normalized(rms: rms)
        signalLevel = signalLevel * 0.72 + normalized * 0.28
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
        case .attending(let wakeWord):
            return ("Te escucho…", wakeWord)
        case .commandRecognized(let command):
            return (command, "Grabación manos libres")
        case .preparing:
            return ("Preparando micrófono", "Destino: \(destination)")
        case .recording:
            return ("Grabando en \(destination)", "Suelta el atajo para terminar")
        case .transcribing:
            return ("Transcribiendo audio", "Audio de \(durationText()) · sigue procesando")
        case .inserting:
            return ("Insertando en \(destination)", "El texto anterior se conserva")
        case .notUnderstood:
            return ("No te he entendido", "Di solo «graba audio»")
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
        let shape: [CGFloat] = [0.55, 0.82, 1, 0.78, 0.5]
        for index in 0..<5 {
            let height = 8 + signalLevel * 34 * shape[index]
            let rect = CGRect(x: 25 + CGFloat(index) * 8, y: bounds.midY - height / 2,
                              width: 4, height: height)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
