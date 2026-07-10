import AppKit

/// Prediction-memory inspector: a live diagram of how each suggestion source
/// is chosen (dictionary vs. personal memory vs. LLM) with real counters,
/// plus a browser of the learned n-grams — which contexts would fire and
/// with how much evidence. Docked to the left of the keyboard panel.
final class MemoryConsole {
    let panel: NSPanel
    private let diagramField = NSTextField(labelWithString: "")
    private let statsField = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    /// Supplies the active language's memory (it can change at runtime).
    var memorySource: () -> PhraseMemory? = { nil }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
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

        let title = NSTextField(labelWithString: "memoria de predicciones")
        title.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.95, alpha: 1)

        let refreshButton = NSButton(title: "refrescar", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .inline
        refreshButton.font = NSFont.systemFont(ofSize: 10)

        let header = NSStackView(views: [title, NSView(), refreshButton])
        header.orientation = .horizontal

        diagramField.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        diagramField.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        diagramField.maximumNumberOfLines = 0
        diagramField.isSelectable = true

        statsField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        statsField.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
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

        // Everything but the header lives inside the scroll (diagram included),
        // so the panel never splits into a fixed half and a scrolling half.
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
        refresh()
    }

    // MARK: - Docking (mirror of ModelConsole, on the opposite side)

    func attach(to parent: NSWindow) {
        if panel.parent != parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        reposition(relativeTo: parent)
        panel.orderFront(nil)
        refresh()
    }

    func reposition(relativeTo parent: NSWindow) {
        let f = parent.frame
        panel.setFrame(NSRect(x: f.minX - 380 - 10, y: f.minY,
                              width: 380, height: max(440, f.height)), display: true)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Content

    @objc private func refreshClicked() { refresh() }

    func refresh() {
        guard panel.isVisible || diagramField.stringValue.isEmpty else { return }
        let mem = QueryLog.shared.phraseMemoryHits
        let llm = QueryLog.shared.phraseLLMCalls
        diagramField.stringValue = """
        CADA PALABRA CONFIRMADA lanza en paralelo:
        ├─ fila inferior · candidatos
        │    diccionario Lexicon (prefijo, instantáneo)
        ├─ fila media · predicciones de palabra
        │    LLM «palabra» (solo mientras tecleas letras)
        └─ GHOST · continuación de frase
             1º memoria personal n-grama   [\(mem) hits]
                contexto 3→2→1 palabras (backoff)
                habla solo si: peso ≥ 2 (≥3 si 1 palabra)
                y ≥ \(Int(PhraseMemory.minShare * 100))% de las continuaciones vistas
                HIT → ghost instantáneo, el LLM NO se llama
             2º LLM Apple/Ollama            [\(llm) llamadas]
                prompt: «next word, only one» + Writing in
                cleaner → 1 palabra → ghost
        """

        let memory = memorySource()
        statsField.stringValue = memory.map {
            "\($0.contextCount) contextos · \($0.sampleCount) muestras aprendidas"
        } ?? "memoria no disponible"

        // Rebuild the scrolled content: diagram + stats + one row per memory.
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for fixed in [diagramField, statsField] {
            stack.addArrangedSubview(fixed)
            fixed.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        guard let memory else { return }
        for entry in memory.topEntries(limit: 120) {
            let continuations = entry.words.prefix(3)
                .map { "\($0.word) ×\(String(format: "%.0f", $0.weight))" }
                .joined(separator: " · ")
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: entry.fires ? "● " : "○ ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: entry.fires
                    ? NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
                    : NSColor(calibratedWhite: 0.4, alpha: 1)
            ]))
            s.append(NSAttributedString(string: entry.context + "  →  ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
            ]))
            s.append(NSAttributedString(string: continuations, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: entry.fires
                    ? NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
                    : NSColor(calibratedWhite: 0.78, alpha: 1)
            ]))
            let field = NSTextField(labelWithAttributedString: s)
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
