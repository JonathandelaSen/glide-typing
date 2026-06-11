import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardViewDelegate {
    private var panel: NSPanel!
    private var keyboardView: KeyboardView!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var settingsController: SettingsWindowController?
    private var toggleMenuItem: NSMenuItem?

    private var language: Language = Settings.language
    private var lexicons: [Language.RawValue: Lexicon] = [:]
    private var bigrams: [Language.RawValue: BigramModel] = [:]

    // Insertion state for smart spacing / candidate replacement / word-delete.
    private var lastInsertedWord: String?
    private var lastInsertedHadLeadingSpace = false
    private var lastOutputEndsInWordChar = false
    /// Last fully-entered word — context for next-word prediction and learning.
    private var contextWord: String?
    /// Letters typed key-by-key, so tapped words also feed prediction context.
    private var tapBuffer = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        lexicons[Language.english.rawValue] = Lexicon(language: .english)
        lexicons[Language.spanish.rawValue] = Lexicon(language: .spanish)
        bigrams[Language.english.rawValue] = BigramModel(language: .english)
        bigrams[Language.spanish.rawValue] = BigramModel(language: .spanish)

        buildPanel()
        buildStatusItem()

        applyHotKey()
        showPanel()
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("GlideBoard: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }
    }

    private func applyHotKey() {
        hotKey = nil // unregister the previous one first
        hotKey = HotKey(keyCode: Settings.hotKeyCode,
                        modifiers: Settings.hotKeyModifiers) { [weak self] in
            self?.togglePanel()
        }
        toggleMenuItem?.title = "Mostrar/Ocultar teclado (\(shortcutDescription(keyCode: Settings.hotKeyCode, modifiers: Settings.hotKeyModifiers)))"
        if hotKey == nil {
            NSLog("GlideBoard: could not register hotkey — it may be taken by another app")
        }
    }

    // MARK: - Panel

    private func buildPanel() {
        keyboardView = KeyboardView(language: language, scale: Settings.scale)
        keyboardView.delegate = self

        let size = keyboardView.frame.size
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = keyboardView

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.minY + 40))
        }
    }

    private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        panel.orderFrontRegardless()
        // Populate the prediction row from the start so it's discoverable.
        showNextWordPredictions()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        resetInsertionState()
        keyboardView.candidates = []
        keyboardView.predictions = []
    }

    private func resetInsertionState() {
        lastInsertedWord = nil
        lastInsertedHadLeadingSpace = false
        lastOutputEndsInWordChar = false
        contextWord = nil
        tapBuffer = ""
    }

    /// A word was fully entered: learn the bigram and refresh the prediction row.
    private func commitWord(_ word: String) {
        bigrams[language.rawValue]?.learn(previous: contextWord, word: word)
        contextWord = word
        showNextWordPredictions()
    }

    private func showNextWordPredictions() {
        var predictions: [String] = []
        if let ctx = contextWord {
            predictions = bigrams[language.rawValue]?.predict(after: ctx) ?? []
        }
        // The bigram corpus is small: when it has nothing for this word, fill
        // the row with the language's most frequent words so it is never empty.
        if predictions.count < 4, let lexicon = lexicons[language.rawValue] {
            for entry in lexicon.entries.prefix(40) {
                let w = entry.word
                if w != contextWord && !predictions.contains(w) {
                    predictions.append(w)
                    if predictions.count == 4 { break }
                }
            }
        }
        keyboardView.predictions = predictions
    }

    /// If letters were typed key-by-key, close that word as prediction context.
    private func flushTapBuffer() {
        guard !tapBuffer.isEmpty else { return }
        let word = tapBuffer
        tapBuffer = ""
        commitWord(word)
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⌨︎"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Mostrar/Ocultar teclado (\(shortcutDescription(keyCode: Settings.hotKeyCode, modifiers: Settings.hotKeyModifiers)))",
                                action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleMenuItem = toggle
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let es = NSMenuItem(title: "Español", action: #selector(setSpanish), keyEquivalent: "")
        es.target = self
        let en = NSMenuItem(title: "English", action: #selector(setEnglish), keyEquivalent: "")
        en.target = self
        menu.addItem(es)
        menu.addItem(en)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de GlideBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func setSpanish() { switchLanguage(.spanish) }
    @objc private func setEnglish() { switchLanguage(.english) }

    private func switchLanguage(_ lang: Language) {
        language = lang
        Settings.language = lang
        keyboardView.setLanguage(lang)
        resetInsertionState()
        settingsController?.reflectLanguage(lang)
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onHotKeyChange = { [weak self] _, _ in self?.applyHotKey() }
            controller.onLanguageChange = { [weak self] lang in self?.switchLanguage(lang) }
            controller.onScaleChange = { [weak self] _ in self?.rebuildPanel() }
            settingsController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Recreate the floating keyboard (e.g. after a size change), keeping its position.
    private func rebuildPanel() {
        let oldOrigin = panel.frame.origin
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        buildPanel()
        panel.setFrameOrigin(oldOrigin)
        if wasVisible { showPanel() }
    }

    // MARK: - KeyboardViewDelegate

    func keyboardView(_ view: KeyboardView, didTap key: Key) {
        switch key.action {
        case .char(let c):
            TextInjector.type(String(c))
            lastOutputEndsInWordChar = c.isLetter
            lastInsertedWord = nil
            if c.isLetter {
                tapBuffer.append(c)
            } else {
                // Punctuation ends the current word.
                flushTapBuffer()
            }
        case .space:
            TextInjector.type(" ")
            lastOutputEndsInWordChar = false
            lastInsertedWord = nil
            flushTapBuffer()
        case .ret:
            TextInjector.pressKey(TextInjector.returnKey)
            resetInsertionState()
            view.candidates = []
            view.predictions = []
        case .backspace:
            if let word = lastInsertedWord {
                // First backspace right after a glide removes the whole word
                // (and the space we added before it).
                let count = word.count + (lastInsertedHadLeadingSpace ? 1 : 0)
                TextInjector.pressKey(TextInjector.backspaceKey, times: count)
                lastInsertedWord = nil
                // If we also removed our leading space, the cursor now sits
                // right after the previous word — the next glide needs a space.
                lastOutputEndsInWordChar = lastInsertedHadLeadingSpace
                lastInsertedHadLeadingSpace = false
                contextWord = nil
                view.candidates = []
                view.predictions = []
            } else {
                TextInjector.pressKey(TextInjector.backspaceKey)
                if !tapBuffer.isEmpty { tapBuffer.removeLast() }
            }
        case .language:
            switchLanguage(language.toggled())
        case .hide:
            hidePanel()
        }
    }

    private func makeDecoder(for view: KeyboardView) -> GestureDecoder? {
        guard let lexicon = lexicons[language.rawValue] else { return nil }
        return GestureDecoder(keyCenters: view.letterCenters,
                              keyWidth: view.unit,
                              lexicon: lexicon)
    }

    func keyboardView(_ view: KeyboardView, didUpdateGlide points: [CGPoint]) {
        guard let decoder = makeDecoder(for: view) else { return }
        let preview = decoder.decodePartial(points: points)
        if !preview.isEmpty {
            view.candidates = preview
        }
    }

    func keyboardView(_ view: KeyboardView, didGlide points: [CGPoint]) {
        guard let decoder = makeDecoder(for: view) else { return }
        let results = decoder.decode(points: points)
        guard let best = results.first else {
            view.candidates = []
            return
        }

        flushTapBuffer()
        let needsSpace = lastOutputEndsInWordChar
        TextInjector.type((needsSpace ? " " : "") + best)
        lastInsertedWord = best
        lastInsertedHadLeadingSpace = needsSpace
        lastOutputEndsInWordChar = true
        view.candidates = results
        commitWord(best) // also refreshes the prediction row above
    }

    func keyboardView(_ view: KeyboardView, didPickCandidate index: Int) {
        // Replace the word just inserted with the chosen alternative.
        guard index < view.candidates.count,
              let current = lastInsertedWord else { return }
        let picked = view.candidates[index]
        guard picked != current else { return }
        TextInjector.pressKey(TextInjector.backspaceKey, times: current.count)
        TextInjector.type(picked)
        lastInsertedWord = picked
        contextWord = picked
        showNextWordPredictions()
    }

    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int) {
        // Insert the predicted word — chained clicks build a phrase.
        guard index < view.predictions.count else { return }
        let picked = view.predictions[index]
        let needsSpace = lastOutputEndsInWordChar
        TextInjector.type((needsSpace ? " " : "") + picked)
        lastInsertedWord = picked
        lastInsertedHadLeadingSpace = needsSpace
        lastOutputEndsInWordChar = true
        view.candidates = []
        commitWord(picked)
    }
}
