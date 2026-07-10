import AppKit
import Carbon

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardViewDelegate, NSTextViewDelegate {
    public override init() { super.init() }

    private var panel: NSPanel!
    private var keyboardView: KeyboardView!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var focusHotKey: HotKey?
    private var transformHotKey: HotKey?
    private var dictationHotKey: HotKey?
    private var sendHotKey: HotKey?
    private var dictationController: DictationController?
    private lazy var dictationOverlay = DictationOverlay()
    /// Captured before the mic starts. It must never be recalculated from the
    /// status overlay's focus when the transcript is ready.
    private var dictationTarget: DictationTarget?
    private var dictationDeliveryInProgress = false
    /// Invalidates delayed delivery/overlay work when the next dictation starts.
    private var dictationSessionID = 0
    /// Plan A: transform the selection of the focused app in place.
    private var transformer: TextTransformer?
    /// Claims the physical Tab key while a ghost is on screen, so the phrase
    /// suggestion can be accepted word by word without touching the mouse.
    private var tabInterceptor: KeyInterceptor?
    private var settingsController: SettingsWindowController?
    private var console: ModelConsole?
    /// The most recent non-self frontmost app — the one receiving injected text.
    private var lastExternalApp: NSRunningApplication?
    private var history: TextHistoryConsole?
    private var phraseMemories: [String: PhraseMemory] = [:]
    private var memoryConsole: MemoryConsole?
    private var phraseMemory: PhraseMemory? { phraseMemories[language.rawValue] }

    /// First run only: replay the persisted sent texts so the memory doesn't
    /// start cold. Live learning (on every send) takes over from there.
    private func seedPhraseMemoryIfEmpty() {
        guard let memory = phraseMemory, memory.contextCount == 0,
              let contents = try? String(contentsOf: TextHistoryConsole.persistedLogURL,
                                         encoding: .utf8) else { return }
        struct StoredEntry: Codable { let date: Date; let text: String }
        let decoder = JSONDecoder()
        for line in contents.split(separator: "\n") {
            guard let entry = try? decoder.decode(StoredEntry.self, from: Data(line.utf8)) else { continue }
            memory.learn(text: entry.text)
        }
    }
    private var toggleMenuItem: NSMenuItem?
    private var focusMenuItem: NSMenuItem?
    private var transformMenuItem: NSMenuItem?
    private var dictationMenuItem: NSMenuItem?
    private var sendMenuItem: NSMenuItem?
    private var spanishMenuItem: NSMenuItem?
    private var englishMenuItem: NSMenuItem?
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
    // Double-space → ". " shortcut: armed by a space typed right after a word.
    private var lastSpaceTapTime: TimeInterval = 0
    private var spaceAfterWord = false
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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        lexicon = Lexicon(languages: [.spanish, .english])
        for word in userDictionary.words {
            lexicon.learn(word)
        }
        bigrams[Language.english.rawValue] = BigramModel(language: .english)
        bigrams[Language.spanish.rawValue] = BigramModel(language: .spanish)
        phraseMemories[Language.english.rawValue] = PhraseMemory(language: .english)
        phraseMemories[Language.spanish.rawValue] = PhraseMemory(language: .spanish)
        seedPhraseMemoryIfEmpty()

        // Track which external app is frontmost so we can hand keyboard focus
        // back to it when injecting text (without hiding our own panel).
        let selfPID = ProcessInfo.processInfo.processIdentifier
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != selfPID else { return }
            Task { @MainActor [weak self] in self?.lastExternalApp = app }
        }

        buildPanel()
        buildStatusItem()
        // Created eagerly so every sent text is recorded (and persisted) even
        // if the console window is never opened.
        history = TextHistoryConsole()
        history?.loadPersisted()
        history?.onSend = { [weak self] text in self?.sendHistoryText(text) }
        history?.onClose = { [weak self] in self?.keyboardView.historyVisible = false }

        QueryLog.shared.sink = { [weak self] query in self?.console?.record(query) }
        QueryLog.shared.phraseAcceptedSink = { [weak self] in self?.console?.recordPhraseAccepted() }

        transformer = TextTransformer(
            provider: { [weak self] in self?.completionProvider },
            targetApp: { [weak self] in self?.lastExternalApp },
            composerDraft: { [weak self] requireFocus in
                // Iteration mode: operate on the board's draft. The ⌘⌥T
                // shortcut requires the composer to hold focus (it can fire
                // from any app); the on-board ✨ chip does not.
                guard let self, self.composerEnabled, !self.composerText.isEmpty,
                      !requireFocus || self.panel.isKeyWindow else { return nil }
                return self.composerText
            },
            preview: { [weak self] text in self?.presentDraft(text) },
            notify: { [weak self] message in
                guard let self else { return }
                if self.panel.isVisible {
                    self.keyboardView.flash(message)
                } else {
                    NSSound.beep()
                }
                NSLog("GlideBoard transform: %@", message)
            })

        applyHotKey()
        applyFocusHotKey()
        applyTransformHotKey()
        applySendHotKey()
        configureDictation()
        applyDictationHotKey()
        applyCompletionEngine()
        showPanel()
        startTargetPolling()
    }

    /// Keep `keyboardView.hasTextTarget` in sync with the focused field so the
    /// composer chip shows "copy" when there's nowhere to inject text.
    private func startTargetPolling() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTargetStatus() }
        }
        RunLoop.main.add(t, forMode: .common)
        targetPollTimer = t
    }

    private func refreshTargetStatus() {
        guard panel.isVisible else { return }
        // While we're mid-delivery the target app is being activated; don't
        // fight that transient state.
        guard !composerDeliveryInProgress else { return }
        keyboardView.hasTextTarget =
            FocusedFieldReader.textTargetStatus(in: lastExternalApp).canAttemptInsertion
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("GlideBoard: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }
    }

    private func applyHotKey() {
        hotKey = nil // unregister the previous one first
        hotKey = HotKey(id: 1,
                        keyCode: Settings.hotKeyCode,
                        modifiers: Settings.hotKeyModifiers) { [weak self] in
            self?.togglePanel()
        }
        applyShortcutDisplay(toggleMenuItem, keyCode: Settings.hotKeyCode,
                             modifiers: Settings.hotKeyModifiers)
        if hotKey == nil {
            NSLog("GlideBoard: could not register hotkey — it may be taken by another app")
        }
    }

    private func applyFocusHotKey() {
        focusHotKey = nil
        focusHotKey = HotKey(id: 2,
                             keyCode: Settings.focusHotKeyCode,
                             modifiers: Settings.focusHotKeyModifiers) { [weak self] in
            self?.focusComposerInput()
        }
        applyShortcutDisplay(focusMenuItem, keyCode: Settings.focusHotKeyCode,
                             modifiers: Settings.focusHotKeyModifiers)
        if focusHotKey == nil {
            NSLog("GlideBoard: could not register composer focus hotkey — it may be taken by another app")
        }
    }

    private func applyTransformHotKey() {
        transformHotKey = nil
        transformHotKey = HotKey(id: 3,
                                 keyCode: Settings.transformHotKeyCode,
                                 modifiers: Settings.transformHotKeyModifiers) { [weak self] in
            self?.transformer?.begin()
        }
        applyShortcutDisplay(transformMenuItem, keyCode: Settings.transformHotKeyCode,
                             modifiers: Settings.transformHotKeyModifiers)
        if transformHotKey == nil {
            NSLog("GlideBoard: could not register transform hotkey — it may be taken by another app")
        }
    }

    private func applySendHotKey() {
        sendHotKey = nil
        sendHotKey = HotKey(id: 5,
                            keyCode: Settings.sendHotKeyCode,
                            modifiers: Settings.sendHotKeyModifiers) { [weak self] in
            self?.sendComposerFromHotKey()
        }
        applyShortcutDisplay(sendMenuItem, keyCode: Settings.sendHotKeyCode,
                             modifiers: Settings.sendHotKeyModifiers)
        if sendHotKey == nil {
            NSLog("GlideBoard: could not register send hotkey — it may be taken by another app")
        }
    }

    /// Global send command: deliver the composer draft to the focused app
    /// without touching the mouse, from anywhere.
    private func sendComposerFromHotKey() {
        guard composerEnabled, !composerText.isEmpty else {
            if panel.isVisible {
                keyboardView.flash(composerEnabled ? "Nada que enviar" : "Activa el área de borrador")
            } else {
                NSSound.beep()
            }
            return
        }
        if panel.isVisible { keyboardView.flash("↪") }
        flushComposerToApp(pressReturn: false)
    }

    private func applyDictationHotKey() {
        dictationHotKey = nil
        dictationHotKey = HotKey(
            id: 4,
            keyCode: Settings.dictationHotKeyCode,
            modifiers: Settings.dictationHotKeyModifiers,
            pressed: { [weak self] in
                Task { await self?.dictationController?.press() }
            },
            released: { [weak self] in
                Task { await self?.dictationController?.release() }
            }
        )
        refreshDictationMenuTitle()
        if dictationHotKey == nil {
            NSLog("GlideBoard: could not register dictation hotkey — it may be taken by another app")
        }
    }

    private func configureDictation() {
        dictationController?.cancel()
        let engine = WhisperKitDictationEngine(model: Settings.dictationModel)
        dictationController = DictationController(
            engine: engine,
            language: { Settings.dictationLanguage.whisperLanguage },
            willStart: { [weak self] in self?.captureDictationTarget() },
            output: { [weak self] transcript in self?.emitDictationTranscript(transcript) },
            stateChanged: { [weak self] state in self?.dictationStateChanged(state) }
        )
    }

    private func emitDictationTranscript(_ transcript: String) {
        let target = dictationTarget ?? .fallback
        let sessionID = dictationSessionID
        switch target {
        case .composer(let selection, let textBeforeSelection):
            let insertion = DictationInsertion.text(transcript: transcript,
                                                    existingText: textBeforeSelection,
                                                    replacingSelection: target.replacesSelection)
            guard !insertion.isEmpty else { return }
            insertDictationIntoComposer(insertion, selection: selection, reveal: false)
            finishDictationDelivery(destination: target.destinationName, sessionID: sessionID)
        case .external(let external):
            let insertion = DictationInsertion.text(transcript: transcript,
                                                    existingText: external.textBeforeSelection,
                                                    replacingSelection: target.replacesSelection)
            guard !insertion.isEmpty else { return }
            deliverDictation(insertion, rawTranscript: transcript, to: external, sessionID: sessionID)
        case .fallback:
            insertDictationFallback(transcript, sessionID: sessionID)
        }
    }

    private func dictationStateChanged(_ state: DictationState) {
        keyboardView?.dictationState = state
        refreshDictationMenuTitle()
        switch state {
        case .idle:
            setStatusIcon("keyboard", description: "GlideBoard")
            if !dictationDeliveryInProgress {
                dictationOverlay.hide()
                dictationTarget = nil
            }
        case .preparing:
            setStatusIcon("mic", description: "GlideBoard — preparando micrófono")
            keyboardView.flash("Preparando micrófono…")
            dictationOverlay.show(.preparing,
                                  destination: (dictationTarget ?? .fallback).destinationName)
        case .recording:
            setStatusIcon("mic.fill", description: "GlideBoard — dictando")
            keyboardView.flash("Dictando… suelta para transcribir")
            dictationOverlay.show(.recording,
                                  destination: (dictationTarget ?? .fallback).destinationName)
        case .transcribing:
            setStatusIcon("waveform", description: "GlideBoard — transcribiendo")
            keyboardView.flash("WhisperKit está transcribiendo…")
            dictationOverlay.show(.transcribing,
                                  destination: (dictationTarget ?? .fallback).destinationName)
        case .failed(let message):
            setStatusIcon("keyboard", description: "GlideBoard")
            keyboardView.flash(message)
            NSLog("GlideBoard dictation: %@", message)
            dictationDeliveryInProgress = false
            dictationTarget = nil
            dictationOverlay.show(.failed(message), destination: "GlideBoard")
            dictationOverlay.hide(after: 2.4)
        }
    }

    /// Snapshot the precise recipient before our own floating UI is shown.
    /// A board composer is intentional only when it actually holds key focus;
    /// otherwise an external app with a real editable field wins.
    private func captureDictationTarget() {
        dictationSessionID += 1
        if panel.isKeyWindow, composerEnabled {
            let selection = keyboardView.composerView.selectedRange()
            let text = composerText as NSString
            let location = min(max(0, selection.location), text.length)
            dictationTarget = .composer(selection: NSRange(location: location,
                                                            length: min(selection.length, text.length - location)),
                                              textBeforeSelection: text.substring(to: location))
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if let external = CapturedTextTarget.capture(in: frontmost) {
            dictationTarget = .external(external)
            lastExternalApp = external.app
        } else {
            dictationTarget = .fallback
        }
    }

    /// Insert in the board with NSTextView replacement semantics: a selected
    /// range is replaced, while a zero-length selection inserts at the caret.
    private func insertDictationIntoComposer(_ insertion: String, selection: NSRange, reveal: Bool) {
        let length = (composerText as NSString).length
        let location = min(max(0, selection.location), length)
        keyboardView.composerView.setSelectedRange(
            NSRange(location: location, length: min(selection.length, length - location))
        )
        keyboardView.composerInsert(insertion)
        noteDictationInsertion(insertion)
        if reveal {
            showPanel()
            panel.makeKey()
            panel.makeFirstResponder(keyboardView.composerView)
            keyboardView.composerView.scrollRangeToVisible(keyboardView.composerView.selectedRange())
        }
    }

    /// No external field was available at start: turn the board into the safe
    /// destination, keep any existing draft, and put the transcript at the
    /// board's current cursor rather than replacing the whole draft.
    private func insertDictationFallback(_ transcript: String, sessionID: Int) {
        guard sessionID == dictationSessionID else { return }
        if !composerEnabled {
            composerEnabled = true
            keyboardView.composerEnabled = true
        }
        let selection = keyboardView.composerView.selectedRange()
        let text = composerText as NSString
        let location = min(max(0, selection.location), text.length)
        let insertion = DictationInsertion.text(transcript: transcript,
                                                existingText: text.substring(to: location),
                                                replacingSelection: selection.length > 0)
        guard !insertion.isEmpty else { return }
        insertDictationIntoComposer(insertion,
                                    selection: NSRange(location: location,
                                                       length: min(selection.length, text.length - location)),
                                    reveal: true)
        finishDictationDelivery(destination: "GlideBoard", sessionID: sessionID)
    }

    private func deliverDictation(_ insertion: String, rawTranscript: String,
                                  to target: CapturedTextTarget, sessionID: Int) {
        dictationDeliveryInProgress = true
        dictationOverlay.show(.inserting, destination: target.app.localizedName ?? "la aplicación")
        target.app.activate()
        attemptDictationDelivery(insertion, rawTranscript: rawTranscript, to: target,
                                 attemptsRemaining: 12, sessionID: sessionID)
    }

    private func attemptDictationDelivery(_ insertion: String, rawTranscript: String,
                                          to target: CapturedTextTarget, attemptsRemaining: Int,
                                          sessionID: Int) {
        guard sessionID == dictationSessionID else { return }
        guard !target.app.isTerminated else {
            dictationDeliveryInProgress = false
            insertDictationFallback(rawTranscript, sessionID: sessionID)
            return
        }
        guard target.app.isActive else {
            if attemptsRemaining == 0 {
                dictationDeliveryInProgress = false
                insertDictationFallback(rawTranscript, sessionID: sessionID)
                return
            }
            target.app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.attemptDictationDelivery(insertion, rawTranscript: rawTranscript, to: target,
                                                attemptsRemaining: attemptsRemaining - 1, sessionID: sessionID)
            }
            return
        }

        // AX replacement is exact and keeps the user's text intact. Chromium
        // editors often reject it, so restore the saved selection then type.
        if target.replaceSelection(with: insertion) {
            noteDictationInsertion(insertion)
            finishDictationDelivery(destination: target.app.localizedName ?? "la aplicación",
                                    sessionID: sessionID)
            return
        }
        guard target.prepareForInsertion() else {
            if attemptsRemaining == 0 {
                dictationDeliveryInProgress = false
                insertDictationFallback(rawTranscript, sessionID: sessionID)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.attemptDictationDelivery(insertion, rawTranscript: rawTranscript, to: target,
                                                attemptsRemaining: attemptsRemaining - 1, sessionID: sessionID)
            }
            return
        }
        TextInjector.type(insertion)
        noteDictationInsertion(insertion)
        finishDictationDelivery(destination: target.app.localizedName ?? "la aplicación",
                                sessionID: sessionID)
    }

    private func noteDictationInsertion(_ text: String) {
        history?.record(text)
        appendRecent(text)
        updateAutoShift()
        keyboardView.flash("Dictado listo")
        requestCompletion()
    }

    private func finishDictationDelivery(destination: String, sessionID: Int) {
        guard sessionID == dictationSessionID else { return }
        dictationDeliveryInProgress = true
        dictationOverlay.show(.inserting, destination: destination)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            guard self.dictationSessionID == sessionID else { return }
            self.dictationDeliveryInProgress = false
            self.dictationTarget = nil
            self.dictationOverlay.hide()
        }
    }

    private func refreshDictationMenuTitle() {
        switch dictationController?.state {
        case .preparing, .recording:
            dictationMenuItem?.title = "Terminar dictado"
            dictationMenuItem?.keyEquivalent = ""
            dictationMenuItem?.isEnabled = true
        case .transcribing:
            dictationMenuItem?.title = "Transcribiendo con WhisperKit…"
            dictationMenuItem?.keyEquivalent = ""
            dictationMenuItem?.isEnabled = false
        default:
            dictationMenuItem?.title = "Iniciar dictado (mantener atajo)"
            applyShortcutDisplay(dictationMenuItem, keyCode: Settings.dictationHotKeyCode,
                                 modifiers: Settings.dictationHotKeyModifiers)
            dictationMenuItem?.isEnabled = true
        }
    }

    // MARK: - Panel

    private func buildPanel() {
        keyboardView = KeyboardView(language: language, scale: Settings.scale)
        keyboardView.delegate = self
        keyboardView.hoverGlideEnabled = Settings.hoverGlide
        keyboardView.composerEnabled = composerEnabled
        keyboardView.dictationState = dictationController?.state ?? .idle
        keyboardView.composerView.delegate = self
        updateAutoShift() // empty composer: start capitalized

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
        panel.alphaValue = Settings.opacity
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
        ensureTabInterceptor()
    }

    private func focusComposerInput() {
        if panel.isKeyWindow {
            releaseComposerFocus(panel: panel) { [weak self] in
                self?.lastExternalApp?.activate()
            }
            // Showing a non-activating panel after the target regains key
            // status keeps GlideBoard visible without stealing focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.showPanel()
            }
            return
        }
        guard composerEnabled else {
            showPanel()
            keyboardView.flash("Activa el área de borrador")
            return
        }
        ensureTabInterceptor()
        focusComposer(panel: panel, composer: keyboardView.composerView)
    }

    /// The event tap can't be created until the Accessibility permission is
    /// granted, so keep retrying whenever the panel is shown.
    private func ensureTabInterceptor() {
        guard tabInterceptor == nil else { return }
        tabInterceptor = KeyInterceptor { [weak self] keyCode, flags, isRepeat in
            guard keyCode == KeyInterceptor.tabKey, !isRepeat,
                  flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
                  let self, self.panel.isVisible,
                  self.tapBuffer.isEmpty,
                  let ghost = self.keyboardView.ghost else { return false }
            // Don't do work inside the tap callback — stalls get the tap
            // disabled by the system.
            DispatchQueue.main.async {
                self.keyboardView.flash("⇥")
                self.acceptGhostFirstWord(self.keyboardView, ghost: ghost)
            }
            return true
        }
        if tabInterceptor == nil {
            NSLog("GlideBoard: Tab interceptor unavailable — waiting for Accessibility permission")
        }
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
        updateAutoShift()
    }

    private func emitBackspace(_ count: Int = 1) {
        if composerEnabled {
            keyboardView.composerDeleteBackward(count)
        } else {
            TextInjector.pressKey(TextInjector.backspaceKey, times: count)
        }
        dropRecent(count)
        updateAutoShift()
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
        updateAutoShift()
    }

    // MARK: - Capitalization

    /// Sentence-start auto-capitalization. Only in composer mode — that's the
    /// one place the text around the caret can be trusted.
    private func updateAutoShift() {
        guard composerEnabled else { return }
        keyboardView.setAutoShift(shouldCapitalize(after: keyboardView.composerTextBeforeCaret))
    }

    private func shouldCapitalize(after text: String) -> Bool {
        guard let last = text.last else { return true }
        if last == "\n" { return true }
        if "¿¡".contains(last) { return true }
        // Sentence enders need the boundary space: "example.com" stays lower.
        guard last == " " else { return false }
        guard let ch = text.reversed().first(where: { $0 != " " }) else { return true }
        return ".!?…".contains(ch)
    }

    /// Capitalization requested via the on-screen shift, applied to a word
    /// inserted whole (glide, prediction chip). Consumes a one-shot shift.
    private func applyShift(_ word: String, view: KeyboardView) -> String {
        switch view.shiftState {
        case .off:
            return word
        case .on:
            view.consumeShift()
            return word.prefix(1).uppercased() + word.dropFirst()
        case .capsLock:
            return word.uppercased()
        }
    }

    /// Replicate the casing the user already typed onto a replacement word
    /// ("H" + pick "hola" → "Hola"; "HOL" → "HOLA").
    private func matchCase(of typed: String, to word: String) -> String {
        guard let first = typed.first, first.isUppercase else { return word }
        if typed.count > 1, typed.allSatisfy({ $0.isUppercase }) { return word.uppercased() }
        return word.prefix(1).uppercased() + word.dropFirst()
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
        // Sent text is definitive material for the personal phrase memory.
        phraseMemory?.learn(text: text)
        memoryConsole?.refresh()
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
            updateAutoShift()
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
        QueryLog.shared.currentSource = source

        // Tier 1 — personal phrase memory: instant, free, and only speaks
        // when its evidence is strong. A hit skips the LLM entirely.
        if let hit = phraseMemory?.suggest(context: context) {
            keyboardView.ghost = hit.word
            QueryLog.shared.record(kind: "✦ frase", isPhrase: true,
                                   engine: "Memoria (\(hit.order)-grama)", ms: 0,
                                   context: context, target: target,
                                   raw: "\(hit.word) ×\(Int(hit.count)) · \(Int(hit.share * 100))% del contexto «\(PhraseMemory.tokens(context).suffix(hit.order).joined(separator: " "))»",
                                   cleaned: hit.word)
            return
        }

        // Tier 2 — LLM (Apple/Ollama).
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

    /// A transform/instruction result lands in the composer for review:
    /// editable with glide, ghosts and predictions active, and injected on
    /// demand with the usual composer flow.
    private func presentDraft(_ text: String) {
        guard composerEnabled else {
            // Without a composer there is nowhere to review: type it directly.
            TextInjector.type(text)
            history?.record(text)
            appendRecent(text)
            return
        }
        keyboardView.composerSetText(text)
        showPanel()
        focusComposer(panel: panel, composer: keyboardView.composerView)
        resetWordState()
        syncWordStateFromComposer()
        showTapCompletions()
        refreshPredictions()
        requestCompletion(afterDelay: 0.3)
    }

    // MARK: - NSTextViewDelegate: the user edits the composer directly
    // (clicking to move the caret, selecting, even typing with the physical
    // keyboard — the panel takes key status without activating the app).

    public func textDidChange(_ notification: Notification) {
        guard composerEnabled, !keyboardView.composerProgrammatic else { return }
        keyboardView.composerContentChanged()
        resetWordState()
        syncWordStateFromComposer()
        showTapCompletions()
        refreshPredictions()
        requestCompletion(afterDelay: 0.5)
    }

    /// Direct composer edits (physical keyboard, caret clicks) bypass the
    /// on-screen keys, so rebuild the word state — partial word and previous
    /// word — from the text before the caret. This is what keeps the
    /// completion and prediction rows alive while typing with both hands.
    private func syncWordStateFromComposer() {
        let before = keyboardView.composerTextBeforeCaret
        lastOutputEndsInWordChar = before.last?.isLetter ?? false
        let words = before.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if before.last?.isLetter == true {
            tapBuffer = words.last ?? ""
            contextWord = words.count >= 2 ? words[words.count - 2] : nil
        } else {
            tapBuffer = ""
            contextWord = words.last
        }
        updateAutoShift()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard composerEnabled, !keyboardView.composerProgrammatic else { return }
        resetWordState()
        syncWordStateFromComposer()
        refreshPredictions()
        if !keyboardView.composerCaretAtEnd {
            keyboardView.ghost = nil
        }
    }

    /// A word was fully entered: learn the bigram, refresh the ghost completion.
    private func commitWord(_ word: String) {
        bigrams[language.rawValue]?.learn(previous: contextWord, word: word)
        contextWord = word
        refreshPredictions()
        requestCompletion()
    }

    /// Local next-word chips for the middle row: instant bigram predictions
    /// after the current context word, whether it was glided or tapped.
    /// While a word is being tap-typed, keep only chips that extend it.
    private func refreshPredictions() {
        guard let previous = contextWord,
              let model = bigrams[language.rawValue] else {
            keyboardView.predictions = []
            return
        }
        var words = model.predict(after: previous, limit: 8)
        if !tapBuffer.isEmpty {
            let norm = String(tapBuffer.lowercased().map(Lexicon.baseKey))
            words = words.filter {
                String($0.lowercased().map(Lexicon.baseKey)).hasPrefix(norm)
                    && $0.count > tapBuffer.count
            }
        }
        keyboardView.predictions = Array(words.prefix(4))
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
        setStatusIcon("keyboard", description: "GlideBoard")

        let menu = NSMenu()
        // Manual enabling so the dictation item can be disabled while transcribing.
        menu.autoenablesItems = false

        // Primary actions. Their global hotkeys render right-aligned like
        // native key equivalents (see applyShortcutDisplay).
        let toggle = NSMenuItem(title: "Mostrar u ocultar el teclado",
                                action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleMenuItem = toggle
        applyShortcutDisplay(toggle, keyCode: Settings.hotKeyCode,
                             modifiers: Settings.hotKeyModifiers)

        let focus = NSMenuItem(title: "Escribir en el borrador",
                               action: #selector(menuFocusComposer), keyEquivalent: "")
        focus.target = self
        menu.addItem(focus)
        focusMenuItem = focus
        applyShortcutDisplay(focus, keyCode: Settings.focusHotKeyCode,
                             modifiers: Settings.focusHotKeyModifiers)

        let transform = NSMenuItem(title: "Transformar texto enfocado",
                                   action: #selector(menuTransform), keyEquivalent: "")
        transform.target = self
        menu.addItem(transform)
        transformMenuItem = transform
        applyShortcutDisplay(transform, keyCode: Settings.transformHotKeyCode,
                             modifiers: Settings.transformHotKeyModifiers)

        let send = NSMenuItem(title: "Enviar el borrador",
                              action: #selector(menuSendComposer), keyEquivalent: "")
        send.target = self
        menu.addItem(send)
        sendMenuItem = send
        applyShortcutDisplay(send, keyCode: Settings.sendHotKeyCode,
                             modifiers: Settings.sendHotKeyModifiers)

        let dictation = NSMenuItem(title: "Iniciar dictado", action: #selector(menuDictation),
                                   keyEquivalent: "")
        dictation.target = self
        menu.addItem(dictation)
        dictationMenuItem = dictation
        refreshDictationMenuTitle()

        menu.addItem(.separator())

        // Keyboard language as a submenu with a checkmark on the active one.
        let languageItem = NSMenuItem(title: "Idioma del teclado", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let es = NSMenuItem(title: "Español", action: #selector(setSpanish), keyEquivalent: "")
        es.target = self
        languageMenu.addItem(es)
        spanishMenuItem = es
        let en = NSMenuItem(title: "English", action: #selector(setEnglish), keyEquivalent: "")
        en.target = self
        languageMenu.addItem(en)
        englishMenuItem = en
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        reflectLanguageInMenu(Settings.language)

        menu.addItem(.separator())

        // Diagnostic consoles, tucked into a submenu.
        let toolsItem = NSMenuItem(title: "Herramientas", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        let debug = NSMenuItem(title: "Consola del modelo (en vivo)…", action: #selector(openDebug), keyEquivalent: "")
        debug.target = self
        toolsMenu.addItem(debug)
        let memory = NSMenuItem(title: "Memoria de predicciones…", action: #selector(openMemoryConsole), keyEquivalent: "")
        memory.target = self
        toolsMenu.addItem(memory)
        let textHistory = NSMenuItem(title: "Histórico de texto introducido…", action: #selector(openHistory), keyEquivalent: "")
        textHistory.target = self
        toolsMenu.addItem(textHistory)
        toolsItem.submenu = toolsMenu
        menu.addItem(toolsItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de GlideBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setStatusIcon(_ symbol: String, description: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: description)
        statusItem.button?.title = ""
    }

    /// Shows the configurable global hotkey right-aligned in the menu, like a
    /// native key equivalent. The actual trigger stays the Carbon hotkey.
    private func applyShortcutDisplay(_ item: NSMenuItem?, keyCode: UInt32, modifiers: UInt32) {
        guard let item else { return }
        if let key = keyEquivalentCharacter(for: keyCode) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifierFlags(fromCarbon: modifiers)
        } else {
            item.keyEquivalent = ""
        }
    }

    private func reflectLanguageInMenu(_ lang: Language) {
        spanishMenuItem?.state = lang == .spanish ? .on : .off
        englishMenuItem?.state = lang == .english ? .on : .off
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func menuFocusComposer() { focusComposerInput() }
    @objc private func menuTransform() { transformer?.begin() }
    @objc private func menuSendComposer() { sendComposerFromHotKey() }
    @objc private func menuDictation() {
        toggleDictation()
    }

    private func toggleDictation() {
        guard let dictationController else { return }
        Task {
            switch dictationController.state {
            case .preparing, .recording:
                await dictationController.release()
            case .idle, .failed:
                await dictationController.press()
            case .transcribing:
                break
            }
        }
    }
    @objc private func setSpanish() { switchLanguage(.spanish) }
    @objc private func setEnglish() { switchLanguage(.english) }

    private func switchLanguage(_ lang: Language) {
        language = lang
        Settings.language = lang
        keyboardView.setLanguage(lang)
        resetInsertionState()
        settingsController?.reflectLanguage(lang)
        reflectLanguageInMenu(lang)
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

    @objc private func openMemoryConsole() {
        if memoryConsole == nil {
            memoryConsole = MemoryConsole()
            memoryConsole?.memorySource = { [weak self] in self?.phraseMemory }
        }
        if memoryConsole!.isVisible {
            memoryConsole!.close()
        } else {
            memoryConsole!.attach(to: panel)
        }
    }

    @objc private func openHistory() {
        if history == nil {
            history = TextHistoryConsole()
            history?.onSend = { [weak self] text in self?.sendHistoryText(text) }
            history?.onClose = { [weak self] in self?.keyboardView.historyVisible = false }
        }
        if history!.isVisible {
            history!.close()
        } else {
            history!.attach(to: panel)
        }
        keyboardView.historyVisible = history!.isVisible
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onHotKeyChange = { [weak self] _, _ in self?.applyHotKey() }
            controller.onFocusHotKeyChange = { [weak self] _, _ in self?.applyFocusHotKey() }
            controller.onDictationHotKeyChange = { [weak self] _, _ in self?.applyDictationHotKey() }
            controller.onTransformHotKeyChange = { [weak self] _, _ in self?.applyTransformHotKey() }
            controller.onSendHotKeyChange = { [weak self] _, _ in self?.applySendHotKey() }
            controller.onDictationModelChange = { [weak self] in self?.configureDictation() }
            controller.onLanguageChange = { [weak self] lang in self?.switchLanguage(lang) }
            controller.onScaleChange = { [weak self] _ in self?.rebuildPanel() }
            controller.onOpacityChange = { [weak self] value in self?.panel.alphaValue = value }
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
        if let memoryConsole, memoryConsole.isVisible {
            memoryConsole.attach(to: panel)
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

    func keyboardViewDidToggleDictation(_ view: KeyboardView) {
        toggleDictation()
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
                refreshPredictions()
                requestCompletion(afterDelay: 0.6)
            } else {
                emitText(String(c))
                lastOutputEndsInWordChar = false
                lastInsertedWord = nil
                // Punctuation ends the current word.
                flushTapBuffer()
            }
        case .text(let s):
            emitText(s)
            lastOutputEndsInWordChar = s.last?.isLetter ?? false
            lastInsertedWord = nil
            flushTapBuffer()
        case .space:
            let now = Date.timeIntervalSinceReferenceDate
            if spaceAfterWord, now - lastSpaceTapTime < 0.8, !view.isAutoRepeating,
               doubleSpaceContextOK() {
                // Double-space: swap the pending space for ". ".
                emitBackspace(1)
                emitText(". ")
                spaceAfterWord = false
                lastSpaceTapTime = 0
                lastOutputEndsInWordChar = false
                lastInsertedWord = nil
                return
            }
            spaceAfterWord = lastOutputEndsInWordChar && !view.isAutoRepeating
            lastSpaceTapTime = now
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
                    refreshPredictions()
                    requestCompletion(afterDelay: 0.6)
                }
            }
        case .tab:
            if composerEnabled {
                emitText("\t")
                lastOutputEndsInWordChar = false
                lastInsertedWord = nil
                flushTapBuffer()
            } else {
                // Field navigation in the target app.
                TextInjector.pressKey(TextInjector.tabKey)
                resetInsertionState()
                view.candidates = []
                view.predictions = []
                view.ghost = nil
            }
        case .escape:
            TextInjector.pressKey(TextInjector.escapeKey)
        case .arrow(let direction):
            if composerEnabled {
                moveComposerCaret(direction)
            } else {
                TextInjector.pressKey(keyCode(for: direction))
                // The cursor moved under us: the transcript and word state
                // no longer describe what's at the caret.
                recentText = ""
                resetInsertionState()
                view.candidates = []
                view.predictions = []
                view.ghost = nil
            }
        case .shift, .layer, .symbolsPage, .emojiCategory, .emojiPageDelta:
            break // layout-only: handled inside KeyboardView
        case .language:
            switchLanguage(language.toggled())
        case .hide:
            hidePanel()
        }
    }

    /// Composer-mode check for the double-space shortcut: exactly one space
    /// at the caret, right after a word character.
    private func doubleSpaceContextOK() -> Bool {
        guard composerEnabled else { return true }
        let before = keyboardView.composerTextBeforeCaret
        guard before.hasSuffix(" "), !before.hasSuffix("  ") else { return false }
        guard let ch = before.dropLast().last else { return false }
        return ch.isLetter || ch.isNumber
    }

    private func moveComposerCaret(_ direction: ArrowKey) {
        let composer = keyboardView.composerView!
        switch direction {
        case .left: composer.moveLeft(nil)
        case .right: composer.moveRight(nil)
        case .up: composer.moveUp(nil)
        case .down: composer.moveDown(nil)
        }
    }

    private func keyCode(for arrow: ArrowKey) -> CGKeyCode {
        switch arrow {
        case .left: return TextInjector.leftArrowKey
        case .right: return TextInjector.rightArrowKey
        case .up: return TextInjector.upArrowKey
        case .down: return TextInjector.downArrowKey
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
        let cased = applyShift(word, view: view)
        let needsSpace = lastOutputEndsInWordChar
        emitText((needsSpace ? " " : "") + cased)
        lastInsertedWord = cased
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
            let picked = matchCase(of: tapBuffer, to: view.candidates[index])
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
        guard picked.lowercased() != current.lowercased() else { return }
        personalWords.learn(picked, weight: 4)
        let cased = matchCase(of: current, to: picked)
        emitBackspace(current.count)
        emitText(cased)
        lastInsertedWord = cased
        contextWord = picked
        refreshPredictions()
        requestCompletion()
    }

    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int) {
        guard index < view.predictions.count else { return }
        let picked = view.predictions[index]

        // No partial word: the chip is the next word — insert it whole.
        // commitWord refills the row with predictions after `picked`, so
        // frequent phrases can be chained chip by chip.
        if tapBuffer.isEmpty {
            let cased = applyShift(picked, view: view)
            let needsSpace = lastOutputEndsInWordChar
            emitText((needsSpace ? " " : "") + cased)
            lastInsertedWord = cased
            lastInsertedHadLeadingSpace = needsSpace
            lastOutputEndsInWordChar = true
            view.candidates = []
            learnIfNew(picked)
            commitWord(picked)
            return
        }

        // Mid-word: the chip extends the partial word — replace it.
        let cased = matchCase(of: tapBuffer, to: picked)
        emitBackspace(tapBuffer.count)
        emitText(cased)
        tapBuffer = ""
        lastInsertedWord = cased
        lastInsertedHadLeadingSpace = false
        lastOutputEndsInWordChar = true
        view.candidates = []
        learnIfNew(picked)
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

    func keyboardViewDidRequestTransform(_ view: KeyboardView) {
        transformer?.begin(fromBoard: true)
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
            updateAutoShift()
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
        refreshPredictions()
        view.ghost = rest
    }

    func keyboardView(_ view: KeyboardView, didPickGhost text: String) {
        QueryLog.shared.recordPhraseAccepted()
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
        refreshPredictions()
        requestCompletion()
    }
}
