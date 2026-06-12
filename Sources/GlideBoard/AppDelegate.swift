import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardViewDelegate {
    private var panel: NSPanel!
    private var keyboardView: KeyboardView!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var settingsController: SettingsWindowController?
    private var debugController: DebugWindowController?
    private var toggleMenuItem: NSMenuItem?

    private var language: Language = Settings.language
    /// Combined Spanish + English + user-learned words: glides and
    /// autocompletion work across both languages without switching.
    private var lexicon: Lexicon!
    private let userDictionary = UserDictionary()
    private var bigrams: [Language.RawValue: BigramModel] = [:]

    // Insertion state for smart spacing / candidate replacement / word-delete.
    private var lastInsertedWord: String?
    private var lastInsertedHadLeadingSpace = false
    private var lastOutputEndsInWordChar = false
    /// Last fully-entered word — context for next-word prediction and learning.
    private var contextWord: String?
    /// Letters typed key-by-key, so tapped words also feed prediction context.
    private var tapBuffer = ""
    /// Rolling transcript of what we've injected — context for AI completion.
    private var recentText = ""
    private var completionProvider: CompletionProvider?
    private var completionTask: Task<Void, Never>?
    private var wordSuggestTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        lexicon = Lexicon(languages: [.spanish, .english])
        for word in userDictionary.words {
            lexicon.learn(word)
        }
        bigrams[Language.english.rawValue] = BigramModel(language: .english)
        bigrams[Language.spanish.rawValue] = BigramModel(language: .spanish)

        buildPanel()
        buildStatusItem()

        applyHotKey()
        applyCompletionEngine()
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
        keyboardView.hoverGlideEnabled = Settings.hoverGlide

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
    }

    private func hidePanel() {
        panel.orderOut(nil)
        resetInsertionState()
        keyboardView.candidates = []
        keyboardView.predictions = []
        keyboardView.ghost = nil
    }

    private func resetInsertionState() {
        lastInsertedWord = nil
        lastInsertedHadLeadingSpace = false
        lastOutputEndsInWordChar = false
        contextWord = nil
        tapBuffer = ""
        recentText = ""
        completionTask?.cancel()
        wordSuggestTask?.cancel()
    }

    // MARK: - AI phrase completion (ghost text)

    private func applyCompletionEngine() {
        completionTask?.cancel()
        keyboardView?.ghost = nil
        switch Settings.completionEngine {
        case "off":
            completionProvider = nil
        case "ollama":
            completionProvider = OllamaProvider()
        default:
            if #available(macOS 26.0, *) {
                completionProvider = SystemModelProvider()
            } else {
                completionProvider = nil
            }
        }
    }

    private func appendRecent(_ s: String) {
        recentText += s
        if recentText.count > 240 {
            recentText = String(recentText.suffix(240))
        }
    }

    private func dropRecent(_ count: Int) {
        recentText = String(recentText.dropLast(count))
    }

    /// The model's context: the real focused-field text up to the caret when
    /// the app exposes it; otherwise our own transcript of what we typed.
    private func completionContext() -> (text: String, source: String) {
        if let fieldText = FocusedFieldReader.textBeforeCursor(),
           !fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (fieldText, "campo (AX)")
        }
        return (recentText, "transcripción interna")
    }

    private func debugLog(_ message: String) {
        debugController?.log(message)
    }

    /// Ask the model for a phrase completion. Pass a delay to debounce while
    /// the user is still tapping letters.
    private func requestCompletion(afterDelay delay: TimeInterval = 0) {
        completionTask?.cancel()
        keyboardView.ghost = nil
        guard let provider = completionProvider else { return }
        let snapshot = recentText
        let (rawContext, source) = completionContext()
        let context = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.split(separator: " ").count >= 2 else { return }
        debugLog("✦ FRASE — fuente: \(source)\ncontexto (\(context.count) car.):\n«\(context)»")
        completionTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            let phrase = try? await provider.complete(context: context)
            await MainActor.run {
                guard let self else { return }
                self.debugLog("✦ FRASE ← \(phrase.map { "«\($0)»" } ?? "(nada)")")
                guard self.recentText == snapshot,
                      let phrase, !phrase.isEmpty else { return }
                self.keyboardView.ghost = phrase
            }
        }
    }

    /// Refresh the word-autocompletion row for the word being tap-typed.
    private func showTapCompletions() {
        guard !tapBuffer.isEmpty else {
            keyboardView.candidates = []
            return
        }
        keyboardView.candidates = lexicon.completions(prefix: tapBuffer)
    }

    /// A word was fully entered: learn the bigram, refresh the ghost completion.
    private func commitWord(_ word: String) {
        bigrams[language.rawValue]?.learn(previous: contextWord, word: word)
        contextWord = word
        wordSuggestTask?.cancel()
        keyboardView.predictions = []
        requestCompletion()
    }

    /// Ask the model for full-word suggestions for the partial word being typed.
    /// They land in the middle row, complementing the instant dictionary row.
    private func requestWordSuggestions(afterDelay delay: TimeInterval) {
        wordSuggestTask?.cancel()
        guard let provider = completionProvider, !tapBuffer.isEmpty else {
            keyboardView.predictions = []
            return
        }
        let partial = tapBuffer
        let (rawContext, source) = completionContext()
        let context = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("PALABRA '\(partial)' — fuente: \(source)\ncontexto (\(context.count) car.):\n«\(context)»")
        wordSuggestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            let words = (try? await provider.suggestWords(context: context, partial: partial)) ?? []
            await MainActor.run {
                guard let self else { return }
                self.debugLog("PALABRA '\(partial)' ← \(words.isEmpty ? "(nada)" : words.joined(separator: ", "))")
                // Don't require the text to be untouched — the suggestion is
                // still valid if it extends whatever the word looks like NOW.
                let current = self.tapBuffer
                guard !current.isEmpty else { return }
                let normCurrent = String(current.lowercased().map(Lexicon.baseKey))
                let valid = words.filter {
                    String($0.lowercased().map(Lexicon.baseKey)).hasPrefix(normCurrent)
                        && $0.count > current.count
                }
                if !valid.isEmpty {
                    self.keyboardView.predictions = valid
                }
            }
        }
    }

    /// If letters were typed key-by-key, close that word as prediction context.
    /// Hand-typed words the dictionary doesn't know get learned: next time
    /// they can be glided and autocompleted.
    private func flushTapBuffer() {
        guard !tapBuffer.isEmpty else { return }
        let word = tapBuffer
        tapBuffer = ""
        learnIfNew(word)
        commitWord(word)
    }

    private func learnIfNew(_ word: String) {
        let w = word.lowercased()
        if lexicon.learn(w) {
            userDictionary.add(w)
        }
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
        let debug = NSMenuItem(title: "Contexto del modelo (debug)…", action: #selector(openDebug), keyEquivalent: "")
        debug.target = self
        menu.addItem(debug)
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

    @objc private func openDebug() {
        if debugController == nil {
            debugController = DebugWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        debugController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onHotKeyChange = { [weak self] _, _ in self?.applyHotKey() }
            controller.onLanguageChange = { [weak self] lang in self?.switchLanguage(lang) }
            controller.onScaleChange = { [weak self] _ in self?.rebuildPanel() }
            controller.onCompletionEngineChange = { [weak self] in self?.applyCompletionEngine() }
            controller.onHoverGlideChange = { [weak self] enabled in self?.keyboardView.hoverGlideEnabled = enabled }
            controller.onUserDictionaryChange = { [weak self] words in
                guard let self else { return }
                self.userDictionary.replaceAll(words)
                // Rebuild the lexicon so removals take effect immediately.
                self.lexicon = Lexicon(languages: [.spanish, .english])
                for word in self.userDictionary.words {
                    self.lexicon.learn(word)
                }
            }
            settingsController = controller
        }
        settingsController?.setUserWords(userDictionary.words)
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
            if c.isLetter {
                // Starting a new tap word right after a word inserted whole
                // (autocompletion, glide, prediction…): add the space for them.
                let needsSpace = tapBuffer.isEmpty && lastInsertedWord != nil
                    && lastOutputEndsInWordChar
                let out = (needsSpace ? " " : "") + String(c)
                TextInjector.type(out)
                appendRecent(out)
                lastOutputEndsInWordChar = true
                lastInsertedWord = nil
                tapBuffer.append(c)
                showTapCompletions()
                requestWordSuggestions(afterDelay: 0.12)
                // Mid-word, the word suggestion takes priority over the phrase
                // ghost — give the latter a longer debounce so they don't queue.
                requestCompletion(afterDelay: 0.6)
            } else {
                TextInjector.type(String(c))
                appendRecent(String(c))
                lastOutputEndsInWordChar = false
                lastInsertedWord = nil
                // Punctuation ends the current word.
                flushTapBuffer()
            }
        case .space:
            TextInjector.type(" ")
            appendRecent(" ")
            lastOutputEndsInWordChar = false
            lastInsertedWord = nil
            flushTapBuffer()
        case .ret:
            TextInjector.pressKey(TextInjector.returnKey)
            resetInsertionState()
            view.candidates = []
            view.predictions = []
            view.ghost = nil
        case .backspace:
            if let word = lastInsertedWord {
                // First backspace right after a glide removes the whole word
                // (and the space we added before it).
                let count = word.count + (lastInsertedHadLeadingSpace ? 1 : 0)
                TextInjector.pressKey(TextInjector.backspaceKey, times: count)
                dropRecent(count)
                lastInsertedWord = nil
                // If we also removed our leading space, the cursor now sits
                // right after the previous word — the next glide needs a space.
                lastOutputEndsInWordChar = lastInsertedHadLeadingSpace
                lastInsertedHadLeadingSpace = false
                contextWord = nil
                view.candidates = []
                view.predictions = []
                view.ghost = nil
            } else {
                TextInjector.pressKey(TextInjector.backspaceKey)
                dropRecent(1)
                if !tapBuffer.isEmpty {
                    tapBuffer.removeLast()
                    showTapCompletions()
                    requestWordSuggestions(afterDelay: 0.12)
                    requestCompletion(afterDelay: 0.6)
                }
            }
        case .language:
            switchLanguage(language.toggled())
        case .hide:
            hidePanel()
        }
    }

    private func makeDecoder(for view: KeyboardView) -> GestureDecoder? {
        return GestureDecoder(keyCenters: view.letterCenters,
                              keyWidth: view.unit,
                              lexicon: lexicon)
    }

    func keyboardView(_ view: KeyboardView, didUpdateGlide points: [CGPoint]) {
        guard let decoder = makeDecoder(for: view) else { return }
        view.ghost = nil
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

        insertGlideWord(best, alternatives: results, view: view)
    }

    func keyboardView(_ view: KeyboardView, didGlideSelect index: Int) {
        // The glide was released on top of a suggestion: insert that word.
        guard index < view.candidates.count else { return }
        let word = view.candidates[index]
        insertGlideWord(word, alternatives: view.candidates, view: view)
    }

    private func insertGlideWord(_ word: String, alternatives: [String], view: KeyboardView) {
        flushTapBuffer()
        let needsSpace = lastOutputEndsInWordChar
        TextInjector.type((needsSpace ? " " : "") + word)
        appendRecent((needsSpace ? " " : "") + word)
        lastInsertedWord = word
        lastInsertedHadLeadingSpace = needsSpace
        lastOutputEndsInWordChar = true
        view.candidates = alternatives
        commitWord(word) // also refreshes the ghost completion
    }

    func keyboardView(_ view: KeyboardView, didPickCandidate index: Int) {
        guard index < view.candidates.count else { return }

        // While tap-typing, the candidate row holds autocompletions for the
        // partial word: replace what's typed so far with the full word.
        if !tapBuffer.isEmpty {
            let picked = view.candidates[index]
            TextInjector.pressKey(TextInjector.backspaceKey, times: tapBuffer.count)
            dropRecent(tapBuffer.count)
            TextInjector.type(picked)
            appendRecent(picked)
            tapBuffer = ""
            lastInsertedWord = picked
            lastInsertedHadLeadingSpace = false
            lastOutputEndsInWordChar = true
            view.candidates = []
            commitWord(picked)
            return
        }

        // Otherwise: replace the word just glided with the chosen alternative.
        guard let current = lastInsertedWord else { return }
        let picked = view.candidates[index]
        guard picked != current else { return }
        TextInjector.pressKey(TextInjector.backspaceKey, times: current.count)
        dropRecent(current.count)
        TextInjector.type(picked)
        appendRecent(picked)
        lastInsertedWord = picked
        contextWord = picked
        requestCompletion()
    }

    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int) {
        // AI word suggestion: replace the partial word with the full word.
        guard index < view.predictions.count, !tapBuffer.isEmpty else { return }
        let picked = view.predictions[index]
        TextInjector.pressKey(TextInjector.backspaceKey, times: tapBuffer.count)
        dropRecent(tapBuffer.count)
        TextInjector.type(picked)
        appendRecent(picked)
        tapBuffer = ""
        lastInsertedWord = picked
        lastInsertedHadLeadingSpace = false
        lastOutputEndsInWordChar = true
        view.candidates = []
        learnIfNew(picked) // AI knows words the dictionary lacks — keep them
        commitWord(picked)
    }

    func keyboardView(_ view: KeyboardView, didFlick direction: FlickDirection) {
        switch direction {
        case .right:
            view.flash("␣")
            keyboardView(view, didTap: Key(action: .space, label: "", unitFrame: .zero))
        case .left:
            view.flash("⌫")
            keyboardView(view, didTap: Key(action: .backspace, label: "", unitFrame: .zero))
        case .down:
            view.flash(".")
            keyboardView(view, didTap: Key(action: .char("."), label: "", unitFrame: .zero))
        case .up:
            // Accept the first suggested word (dictionary row, then AI row).
            if !view.candidates.isEmpty {
                view.flash("✓")
                keyboardView(view, didPickCandidate: 0)
            } else if !view.predictions.isEmpty {
                view.flash("✓")
                keyboardView(view, didPickPrediction: 0)
            } else {
                view.flash("✓?") // nothing to accept yet
            }
        }
    }

    func keyboardView(_ view: KeyboardView, didSetHoverGlide enabled: Bool) {
        Settings.hoverGlide = enabled
        settingsController?.reflectHoverGlide(enabled)
    }

    func keyboardView(_ view: KeyboardView, didEdit action: EditAction) {
        switch action {
        case .paste:
            view.flash("pegar")
            TextInjector.pressKey(TextInjector.vKey, flags: .maskCommand)
            lastInsertedWord = nil
            // Keep the transcript in sync: we know exactly what got pasted.
            if let pasted = NSPasteboard.general.string(forType: .string) {
                appendRecent(pasted)
                lastOutputEndsInWordChar = pasted.last?.isLetter ?? false
            } else {
                lastOutputEndsInWordChar = true
            }
        case .selectAllCopy:
            view.flash("copiado")
            // Spaced out: the target app must process each step before the
            // next (select-all → copy → collapse selection).
            TextInjector.pressSequence([
                (TextInjector.aKey, .maskCommand),
                (TextInjector.cKey, .maskCommand),
                (TextInjector.rightArrowKey, [])
            ])
        case .deleteToEnd:
            view.flash("⌫ final")
            // Select to the end, then forward-delete (a no-op when nothing
            // is selected, unlike backspace).
            TextInjector.pressSequence([
                (TextInjector.downArrowKey, [.maskCommand, .maskShift]),
                (TextInjector.forwardDeleteKey, [])
            ])
            lastInsertedWord = nil
        case .deleteToStart:
            view.flash("⌫ inicio")
            TextInjector.pressSequence([
                (TextInjector.upArrowKey, [.maskCommand, .maskShift]),
                (TextInjector.forwardDeleteKey, [])
            ])
            lastInsertedWord = nil
            lastOutputEndsInWordChar = false
            // Everything before the cursor is gone — so is our transcript.
            recentText = ""
            contextWord = nil
        case .deleteAll:
            view.flash("⌫ todo")
            TextInjector.pressSequence([
                (TextInjector.aKey, .maskCommand),
                (TextInjector.forwardDeleteKey, [])
            ])
            resetInsertionState()
            view.candidates = []
            view.predictions = []
            view.ghost = nil
        }
    }

    func keyboardView(_ view: KeyboardView, didPickGhost text: String) {
        // Mid-word the continuation glues onto the partial word — no space.
        let needsSpace = lastOutputEndsInWordChar && tapBuffer.isEmpty
        tapBuffer = ""
        TextInjector.type((needsSpace ? " " : "") + text)
        appendRecent((needsSpace ? " " : "") + text)
        // Backspace right after accepting removes the whole phrase.
        lastInsertedWord = text
        lastInsertedHadLeadingSpace = needsSpace
        lastOutputEndsInWordChar = true
        view.ghost = nil
        view.candidates = []

        // Feed the phrase's word pairs to the bigram model.
        let words = (contextWord.map { [$0] } ?? [])
            + text.lowercased().split(separator: " ").map(String.init)
        if words.count >= 2 {
            for i in 1..<words.count {
                bigrams[language.rawValue]?.learn(previous: words[i - 1], word: words[i])
            }
        }
        contextWord = words.last
        requestCompletion()
    }
}
