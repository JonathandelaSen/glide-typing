import AppKit
import Carbon

/// Borderless non-activating panel that can still take key status — needed so
/// the composer text view can show a caret without activating the app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardViewDelegate, NSTextViewDelegate {
    private var panel: NSPanel!
    private var keyboardView: KeyboardView!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var settingsController: SettingsWindowController?
    private var console: ModelConsole?
    /// The most recent non-self frontmost app — the one receiving injected text.
    private var lastExternalApp: NSRunningApplication?
    private var history: TextHistoryConsole?
    private var evalExporter: EvalExporter?
    private var evalCaptureMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    /// Polls whether the focused app has an editable field, so the composer
    /// chip can switch between "insert" and "copy".
    private var targetPollTimer: Timer?

    private var language: Language = Settings.language
    /// Combined Spanish + English + user-learned words: glides and
    /// autocompletion work across both languages without switching.
    private var lexicon: Lexicon!
    private let userDictionary = UserDictionary()
    private var bigrams: [Language.RawValue: BigramModel] = [:]
    private let personalWords = PersonalWordModel()

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
    /// Composer mode: text is composed in the panel and inserted on demand.
    private var composerEnabled = Settings.composerMode
    private var composerDeliveryInProgress = false
    /// A Return press that arrived while a delivery was still in flight
    /// (two-step Enter); sent right after the text lands.
    private var pendingReturn = false
    /// The panel was ordered out to hand key focus back to the target app;
    /// restore it when the delivery settles.
    private var panelHiddenForDelivery = false
    /// The composer text view is the source of truth in composer mode.
    private var composerText: String { keyboardView?.composerString ?? "" }
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

        // Track which external app is frontmost so we can hand keyboard focus
        // back to it when injecting text (without hiding our own panel).
        let selfPID = ProcessInfo.processInfo.processIdentifier
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != selfPID else { return }
            self?.lastExternalApp = app
        }

        buildPanel()
        buildStatusItem()
        // Created eagerly so every sent text is recorded (and persisted) even
        // if the console window is never opened.
        history = TextHistoryConsole()
        history?.loadPersisted()
        history?.onSend = { [weak self] text in self?.sendHistoryText(text) }

        QueryLog.shared.sink = { [weak self] query in self?.console?.record(query) }
        QueryLog.shared.phraseAcceptedSink = { [weak self] in self?.console?.recordPhraseAccepted() }

        // Eval workspace (<repo>/evals): phrase-completion contexts become
        // cases once the sent text reveals what the user wrote after them.
        evalExporter = EvalExporter()
        QueryLog.shared.evalSink = { [weak self] query in self?.evalExporter?.attach(query) }
        applyHotKey()
        applyCompletionEngine()
        showPanel()
        startTargetPolling()
    }

    /// Keep `keyboardView.hasTextTarget` in sync with the focused field so the
    /// composer chip shows "copy" when there's nowhere to inject text.
    private func startTargetPolling() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            // While we're mid-delivery the target app is being activated; don't
            // fight that transient state.
            guard !self.composerDeliveryInProgress else { return }
            self.keyboardView.hasTextTarget =
                FocusedFieldReader.textTargetStatus(in: self.lastExternalApp).canAttemptInsertion
        }
        RunLoop.main.add(t, forMode: .common)
        targetPollTimer = t
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
        keyboardView.composerEnabled = composerEnabled
        keyboardView.composerView.delegate = self

        let size = keyboardView.frame.size
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        // Key status only when the composer text view is clicked — typing in
        // the target app is unaffected until then.
        panel.becomesKeyOnlyIfNeeded = true
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

    // MARK: - Output sink: composer buffer or direct injection

    private func emitText(_ s: String) {
        if composerEnabled {
            keyboardView.composerInsert(s)
        } else {
            TextInjector.type(s)
            history?.record(s)
        }
        appendRecent(s)
    }

    private func emitBackspace(_ count: Int = 1) {
        if composerEnabled {
            keyboardView.composerDeleteBackward(count)
        } else {
            TextInjector.pressKey(TextInjector.backspaceKey, times: count)
        }
        dropRecent(count)
    }

    private func emitBackspaceWord() {
        if composerEnabled {
            keyboardView.composerDeleteWord()
        } else {
            // Option+Delete removes the previous word in most macOS fields.
            TextInjector.pressKey(TextInjector.backspaceKey, flags: .maskAlternate)
        }
        // We can't know exactly how many characters the app dropped; clear our
        // shadow of the recent text so we don't trust a stale transcript.
        recentText = ""
        contextWord = nil
    }

    /// Type the composer buffer into the focused app (optionally with Return).
    private func flushComposerToApp(pressReturn: Bool) {
        guard !composerDeliveryInProgress else {
            if pressReturn {
                // Two-step Enter: the Return press arrived while the text is
                // still being delivered. Queue it so it lands after the text
                // instead of being dropped.
                pendingReturn = true
            } else {
                keyboardView.flash("Buscando campo de texto…")
            }
            return
        }
        guard let target = lastExternalApp, !target.isTerminated else {
            keyboardView.flash("Selecciona un campo de texto")
            return
        }
        let text = composerText
        // Safety net: persist the text BEFORE any delivery step can lose it.
        history?.record(text)
        // The sent text is the ground truth for pending completion captures.
        evalExporter?.finalize(sentText: text)
        composerDeliveryInProgress = true
        if panel.isKeyWindow {
            // The composer was clicked, so our nonactivating panel holds key
            // focus — while the target often remains the *active* app, which
            // makes activate() a no-op. The window server keeps routing
            // keyboard events to the key panel, so the synthetic keystrokes
            // would come back to us and vanish. Dropping first responder is
            // not enough: the panel must leave the screen for key focus to
            // return to the target. It reappears when delivery settles.
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panelHiddenForDelivery = true
        }
        target.activate()
        deliverComposer(text, pressReturn: pressReturn, attemptsRemaining: 12)
    }

    /// Re-send a history entry to the focused app. Uses the same reliable
    /// delivery path as the composer but leaves the composer untouched and
    /// does not re-record the entry (it is already in the history).
    private func sendHistoryText(_ text: String) {
        guard !composerDeliveryInProgress else {
            keyboardView.flash("Entrega en curso…")
            return
        }
        guard let target = lastExternalApp, !target.isTerminated else {
            keyboardView.flash("Selecciona un campo de texto")
            return
        }
        composerDeliveryInProgress = true
        if panel.isKeyWindow || history?.panel.isKeyWindow == true {
            // Same nonactivating-panel gotcha as flushComposerToApp: while any
            // of our panels holds key focus, synthetic keystrokes route back
            // to us. The history panel is a child of the keyboard panel, so
            // ordering the parent out takes both off screen.
            panel.makeFirstResponder(nil)
            history?.panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panelHiddenForDelivery = true
        }
        target.activate()
        deliverComposer(text, pressReturn: false, attemptsRemaining: 12,
                        fromHistory: true)
    }

    /// Delivery finished or gave up: restore the panel if it was hidden.
    private func finishDelivery() {
        composerDeliveryInProgress = false
        pendingReturn = false
        if panelHiddenForDelivery {
            panelHiddenForDelivery = false
            panel.orderFrontRegardless()
        }
    }

    private func deliverComposer(_ text: String, pressReturn: Bool, attemptsRemaining: Int,
                                 fromHistory: Bool = false) {
        guard attemptsRemaining > 0 else {
            finishDelivery()
            keyboardView.flash(fromHistory ? "No entregado" : "No entregado; el texto sigue aquí")
            return
        }
        let retry = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.deliverComposer(text, pressReturn: pressReturn,
                                      attemptsRemaining: attemptsRemaining - 1,
                                      fromHistory: fromHistory)
            }
        }
        // activate() is asynchronous, and per-app AX focus can't detect where
        // keystrokes actually go — an app reports a focused element even while
        // in the background. Require the whole chain: target frontmost, our
        // panel no longer key, and system keyboard focus provably not ours.
        guard let target = lastExternalApp, !target.isTerminated, target.isActive,
              !panel.isKeyWindow else {
            retry()
            return
        }
        if FocusedFieldReader.systemFocusPid() == ProcessInfo.processInfo.processIdentifier {
            retry()
            return
        }
        switch FocusedFieldReader.textTargetStatus(in: target) {
        case .editable, .unknown:
            break
        case .notEditable:
            retry()
            return
        }

        if !text.isEmpty { TextInjector.type(text) }
        if pressReturn || pendingReturn { TextInjector.pressKey(TextInjector.returnKey) }
        finishDelivery()
        if fromHistory {
            keyboardView.flash("Enviado desde el histórico")
            return
        }
        if composerText == text {
            keyboardView.composerClear()
        } else {
            keyboardView.flash("Enviado; cambios nuevos conservados")
        }
        resetInsertionState()
        keyboardView.candidates = []
        keyboardView.predictions = []
        keyboardView.ghost = nil
    }

    /// Snapshot used to discard stale async results.
    private var contextFingerprint: String {
        composerEnabled ? composerText : recentText
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
        if composerEnabled {
            // Up to the caret: editing mid-text completes from there.
            return (keyboardView.composerTextBeforeCaret, "borrador")
        }
        if let fieldText = FocusedFieldReader.textBeforeCursor(),
           !fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (fieldText, "campo (AX)")
        }
        return (recentText, "transcripción interna")
    }


    /// Ask the model for a phrase completion. Pass a delay to debounce while
    /// the user is still tapping letters.
    private func requestCompletion(afterDelay delay: TimeInterval = 0) {
        completionTask?.cancel()
        keyboardView.ghost = nil
        guard let provider = completionProvider else { return }
        let snapshot = contextFingerprint
        let (rawContext, source) = completionContext()
        let context = CompletionCleaner.contextForModel(rawContext)
        guard context.split(separator: " ").count >= 2 else { return }
        // Where the text will land (app, window, field) — read via AX so the
        // model knows if it's completing a mail, a chat, a code editor…
        let target = FocusedFieldReader.targetDescription(in: lastExternalApp)
        // Captured at request time: even if the next word cancels this query,
        // the context is a valid eval case once the ground truth is known.
        evalExporter?.captureContext(context, target: target)
        QueryLog.shared.currentSource = source
        completionTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            let phrase = try? await provider.complete(context: context, target: target)
            guard let self else { return }
            guard self.contextFingerprint == snapshot,
                  let phrase, !phrase.isEmpty else { return }
            self.keyboardView.ghost = phrase
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

    private func resetWordState() {
        tapBuffer = ""
        lastInsertedWord = nil
    }

    // MARK: - NSTextViewDelegate: the user edits the composer directly
    // (clicking to move the caret, selecting, even typing with the physical
    // keyboard — the panel takes key status without activating the app).

    func textDidChange(_ notification: Notification) {
        guard composerEnabled, !keyboardView.composerProgrammatic else { return }
        keyboardView.composerContentChanged()
        resetWordState()
        lastOutputEndsInWordChar = keyboardView.composerTextBeforeCaret.last?.isLetter ?? false
        keyboardView.candidates = []
        keyboardView.predictions = []
        requestCompletion(afterDelay: 0.5)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard composerEnabled, !keyboardView.composerProgrammatic else { return }
        resetWordState()
        if !keyboardView.composerCaretAtEnd {
            keyboardView.ghost = nil
        }
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
        QueryLog.shared.currentSource = source
        wordSuggestTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            let words = (try? await provider.suggestWords(context: context, partial: partial)) ?? []
            guard let self else { return }
            // Don't require the text to be untouched — the suggestion is
            // still valid if it extends whatever the word looks like NOW.
            let current = self.tapBuffer
            guard !current.isEmpty else { return }
            let normCurrent = String(current.lowercased().map(Lexicon.baseKey))
            let valid = words.filter {
                let norm = String($0.lowercased().map(Lexicon.baseKey))
                return (norm.hasPrefix(normCurrent) || Lexicon.isSubsequence(normCurrent, of: norm))
                    && $0.count > current.count
            }
            if !valid.isEmpty {
                self.keyboardView.predictions = valid
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
        let debug = NSMenuItem(title: "Consola del modelo (en vivo)…", action: #selector(openDebug), keyEquivalent: "")
        debug.target = self
        menu.addItem(debug)
        let textHistory = NSMenuItem(title: "Histórico de texto introducido…", action: #selector(openHistory), keyEquivalent: "")
        menu.addItem(textHistory)
        let evalCapture = NSMenuItem(title: "Generar evals al escribir",
                                     action: #selector(toggleEvalCapture), keyEquivalent: "")
        evalCapture.target = self
        evalCapture.state = Settings.evalCaptureEnabled ? .on : .off
        menu.addItem(evalCapture)
        evalCaptureMenuItem = evalCapture
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
        if console == nil {
            console = ModelConsole()
        }
        if console!.isVisible {
            console!.close()
        } else {
            console!.attach(to: panel)
        }
    }

    @objc private func openHistory() {
        if history == nil {
            history = TextHistoryConsole()
            history?.onSend = { [weak self] text in self?.sendHistoryText(text) }
        }
        if history!.isVisible {
            history!.close()
        } else {
            history!.attach(to: panel)
        }
        keyboardView.historyVisible = history!.isVisible
    }

    // MARK: - Settings

    @objc private func toggleEvalCapture() {
        Settings.evalCaptureEnabled.toggle()
        evalCaptureMenuItem?.state = Settings.evalCaptureEnabled ? .on : .off
        keyboardView.flash(Settings.evalCaptureEnabled
                           ? "Generando evals al escribir"
                           : "Generación de evals desactivada")
    }

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onHotKeyChange = { [weak self] _, _ in self?.applyHotKey() }
            controller.onLanguageChange = { [weak self] lang in self?.switchLanguage(lang) }
            controller.onScaleChange = { [weak self] _ in self?.rebuildPanel() }
            controller.onCompletionEngineChange = { [weak self] in self?.applyCompletionEngine() }
            controller.onHoverGlideChange = { [weak self] enabled in self?.keyboardView.hoverGlideEnabled = enabled }
            controller.onComposerModeChange = { [weak self] enabled in
                guard let self else { return }
                // Don't lose composed text when switching modes.
                if !enabled && !self.composerText.isEmpty {
                    self.flushComposerToApp(pressReturn: false)
                }
                self.composerEnabled = enabled
                self.keyboardView.composerEnabled = enabled
            }
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
        if let console, console.isVisible {
            console.attach(to: panel)
        }
        if let history, history.isVisible {
            history.attach(to: panel)
            keyboardView.historyVisible = true
        }
    }

    // MARK: - KeyboardViewDelegate

    func keyboardViewDidToggleHistory(_ view: KeyboardView) {
        openHistory()
    }

    func keyboardView(_ view: KeyboardView, didRepeatBackspaceByWord byWord: Bool) {
        if byWord {
            emitBackspaceWord()
        } else {
            emitBackspace()
            if !tapBuffer.isEmpty { tapBuffer.removeLast() }
        }
        // A sustained hold has left the previous-word/glide state meaningless.
        lastInsertedWord = nil
        view.candidates = []
        view.predictions = []
        view.ghost = nil
    }

    func keyboardView(_ view: KeyboardView, didTap key: Key) {
        switch key.action {
        case .char(let c):
            if c.isLetter {
                // Starting a new tap word right after a word inserted whole
                // (autocompletion, glide, prediction…): add the space for them.
                let needsSpace = tapBuffer.isEmpty && lastInsertedWord != nil
                    && lastOutputEndsInWordChar
                let out = (needsSpace ? " " : "") + String(c)
                emitText(out)
                lastOutputEndsInWordChar = true
                lastInsertedWord = nil
                tapBuffer.append(c)
                showTapCompletions()
                requestWordSuggestions(afterDelay: 0.12)
                // Mid-word, the word suggestion takes priority over the phrase
                // ghost — give the latter a longer debounce so they don't queue.
                requestCompletion(afterDelay: 0.6)
            } else {
                emitText(String(c))
                lastOutputEndsInWordChar = false
                lastInsertedWord = nil
                // Punctuation ends the current word.
                flushTapBuffer()
            }
        case .space:
            emitText(" ")
            lastOutputEndsInWordChar = false
            lastInsertedWord = nil
            flushTapBuffer()
        case .ret:
            if composerEnabled {
                // With composed text: insert it into the app but don't submit,
                // so you can review or keep composing. With an empty buffer:
                // forward a plain Return to submit in the target app without
                // leaving the keyboard.
                flushComposerToApp(pressReturn: composerText.isEmpty)
            } else {
                TextInjector.pressKey(TextInjector.returnKey)
                resetInsertionState()
                view.candidates = []
                view.predictions = []
                view.ghost = nil
            }
        case .backspace:
            if let word = lastInsertedWord {
                // First backspace right after a glide removes the whole word
                // (and the space we added before it).
                let count = word.count + (lastInsertedHadLeadingSpace ? 1 : 0)
                emitBackspace(count)
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
                emitBackspace()
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
        let model = bigrams[language.rawValue]
        let previous = contextWord
        let results = decoder.decode(
            points: points,
            activeLanguage: language,
            contextScore: { model?.score(previous: previous, word: $0) ?? 0 },
            personalScore: { [personalWords] in personalWords.score($0) }
        )
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
        personalWords.learn(word, weight: index == 0 ? 1 : 3)
        insertGlideWord(word, alternatives: view.candidates, view: view)
    }

    private func insertGlideWord(_ word: String, alternatives: [String], view: KeyboardView) {
        flushTapBuffer()
        let needsSpace = lastOutputEndsInWordChar
        emitText((needsSpace ? " " : "") + word)
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
            emitBackspace(tapBuffer.count)
            emitText(picked)
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
        personalWords.learn(picked, weight: 4)
        emitBackspace(current.count)
        emitText(picked)
        lastInsertedWord = picked
        contextWord = picked
        requestCompletion()
    }

    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int) {
        // AI word suggestion: replace the partial word with the full word.
        guard index < view.predictions.count, !tapBuffer.isEmpty else { return }
        let picked = view.predictions[index]
        emitBackspace(tapBuffer.count)
        emitText(picked)
        tapBuffer = ""
        lastInsertedWord = picked
        lastInsertedHadLeadingSpace = false
        lastOutputEndsInWordChar = true
        view.candidates = []
        learnIfNew(picked) // AI knows words the dictionary lacks — keep them
        commitWord(picked)
    }

    func keyboardView(_ view: KeyboardView, didFlick direction: FlickDirection, long: Bool) {
        switch direction {
        case .right:
            view.flash(".")
            keyboardView(view, didTap: Key(action: .char("."), label: "", unitFrame: .zero))
        case .left:
            view.flash("⌫")
            keyboardView(view, didTap: Key(action: .backspace, label: "", unitFrame: .zero))
        case .down:
            view.flash("␣")
            keyboardView(view, didTap: Key(action: .space, label: "", unitFrame: .zero))
        case .up:
            // Phrase continuation is the highest-value shortcut when the user
            // is between words; mid-word, complete that word first.
            // Partial acceptance: a short flick takes just the ghost's first
            // word (an 80%-right suggestion is no longer worth zero); a long
            // flick takes the whole phrase.
            if tapBuffer.isEmpty, let ghost = view.ghost {
                view.flash("✦")
                if long {
                    keyboardView(view, didPickGhost: ghost)
                } else {
                    acceptGhostFirstWord(view, ghost: ghost)
                }
            } else if !view.candidates.isEmpty {
                view.flash("✓")
                keyboardView(view, didPickCandidate: 0)
            } else if !view.predictions.isEmpty {
                view.flash("✓")
                keyboardView(view, didPickPrediction: 0)
            } else {
                // Nothing to accept: a swipe up here means "submit" (Return).
                view.flash("↩︎")
                keyboardView(view, didRequestInsert: true)
            }
        }
    }

    func keyboardView(_ view: KeyboardView, didSetHoverGlide enabled: Bool) {
        Settings.hoverGlide = enabled
        settingsController?.reflectHoverGlide(enabled)
    }

    func keyboardView(_ view: KeyboardView, didRequestInsert pressReturn: Bool) {
        guard composerEnabled else {
            // Direct-typing mode: there's no buffer to flush, so honor a
            // requested Return by sending it to the focused app. activate()
            // is asynchronous — give the target time to become frontmost or
            // the keystroke lands in our own panel.
            if pressReturn {
                lastExternalApp?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    TextInjector.pressKey(TextInjector.returnKey)
                }
            }
            return
        }
        view.flash("↪")
        flushComposerToApp(pressReturn: pressReturn)
    }

    func keyboardViewDidRequestCopy(_ view: KeyboardView) {
        let text = composerText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        history?.record(text)
        view.flash("copiado")
    }

    func keyboardViewDidResize(_ view: KeyboardView) {
        let size = view.currentSize()
        view.setFrameSize(size)
        var frame = panel.frame
        frame.size = size
        // Same origin: the panel grows upward, the keys stay where they are.
        panel.setFrame(frame, display: true)
        if let console, console.isVisible {
            console.reposition(relativeTo: panel)
        }
    }

    func keyboardView(_ view: KeyboardView, didEdit action: EditAction) {
        // In composer mode the actions operate on the buffer itself.
        if composerEnabled {
            switch action {
            case .paste:
                view.flash("pegar")
                if let pasted = NSPasteboard.general.string(forType: .string) {
                    emitText(pasted)
                    lastOutputEndsInWordChar = pasted.last?.isLetter ?? false
                }
            case .selectAllCopy:
                view.flash("copiado")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(composerText, forType: .string)
            case .deleteToEnd:
                view.flash("⌫ final")
                view.composerDeleteToEnd()
            case .deleteToStart:
                view.flash("⌫ inicio")
                view.composerDeleteToStart()
                resetWordState()
            case .deleteAll:
                view.flash("⌫ todo")
                view.composerClear()
                resetInsertionState()
                view.candidates = []
                view.predictions = []
                view.ghost = nil
            }
            return
        }

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

    /// Partial acceptance: insert only the ghost's first word and keep the
    /// rest on screen, so the remaining words can be taken one flick at a
    /// time (instantly, no new model round-trip) or typed over.
    private func acceptGhostFirstWord(_ view: KeyboardView, ghost: String) {
        let words = ghost.split(separator: " ").map(String.init)
        guard let first = words.first else { return }
        let rest = words.dropFirst().joined(separator: " ")
        guard !rest.isEmpty else {
            keyboardView(view, didPickGhost: ghost) // single word: same thing
            return
        }
        QueryLog.shared.recordPhraseAccepted()
        evalExporter?.ghostAccepted(ghost)
        let needsSpace = lastOutputEndsInWordChar && tapBuffer.isEmpty
        tapBuffer = ""
        emitText((needsSpace ? " " : "") + first)
        // Backspace right after accepting removes that word.
        lastInsertedWord = first
        lastInsertedHadLeadingSpace = needsSpace
        lastOutputEndsInWordChar = true
        bigrams[language.rawValue]?.learn(previous: contextWord, word: first.lowercased())
        contextWord = first.lowercased()
        view.candidates = []
        view.ghost = rest
    }

    func keyboardView(_ view: KeyboardView, didPickGhost text: String) {
        QueryLog.shared.recordPhraseAccepted()
        evalExporter?.ghostAccepted(text)
        // Mid-word the continuation glues onto the partial word — no space.
        let needsSpace = lastOutputEndsInWordChar && tapBuffer.isEmpty
        tapBuffer = ""
        emitText((needsSpace ? " " : "") + text)
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
