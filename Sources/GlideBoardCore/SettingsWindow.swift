import AppKit
import Carbon

/// Button that records a keyboard shortcut when clicked.
final class ShortcutField: NSButton {
    var keyCode: UInt32 = 0
    var carbonMods: UInt32 = 0
    var onChange: ((UInt32, UInt32) -> Void)?
    private var monitor: Any?

    convenience init(keyCode: UInt32, carbonMods: UInt32) {
        self.init(frame: .zero)
        self.keyCode = keyCode
        self.carbonMods = carbonMods
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    private func refreshTitle() {
        title = shortcutDescription(keyCode: keyCode, modifiers: carbonMods)
    }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        title = "Pulsa el atajo… (⎋ cancela)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape cancels
                self.endRecording()
                return nil
            }
            let mods = carbonModifiers(from: event.modifierFlags)
            // Require at least one real modifier (shift alone would swallow normal typing).
            if mods & ~UInt32(shiftKey) == 0 {
                NSSound.beep()
                return nil
            }
            self.keyCode = UInt32(event.keyCode)
            self.carbonMods = mods
            self.endRecording()
            self.onChange?(self.keyCode, self.carbonMods)
            return nil
        }
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTitle()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onHotKeyChange: ((UInt32, UInt32) -> Void)?
    var onFocusHotKeyChange: ((UInt32, UInt32) -> Void)?
    var onDictationHotKeyChange: ((UInt32, UInt32) -> Void)?
    var onTransformHotKeyChange: ((UInt32, UInt32) -> Void)?
    var onDictationModelChange: (() -> Void)?
    var onLanguageChange: ((Language) -> Void)?
    var onScaleChange: ((Double) -> Void)?
    var onOpacityChange: ((Double) -> Void)?
    var onCompletionEngineChange: (() -> Void)?
    var onHoverGlideChange: ((Bool) -> Void)?
    var onComposerModeChange: ((Bool) -> Void)?
    var onUserDictionaryChange: (([String]) -> Void)?
    private var dictionaryView: NSTextView!
    private var hoverCheck: NSButton!

    private var scaleLabel: NSTextField!
    private var opacityLabel: NSTextField!
    private var languagePopup: NSPopUpButton!
    private var enginePopup: NSPopUpButton!
    private var ollamaModelPopup: NSPopUpButton!
    private var dictationModelPopup: NSPopUpButton!
    private var dictationLanguagePopup: NSPopUpButton!
    private var ollamaModelsTask: Task<Void, Never>?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 570),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Ajustes de GlideBoard"
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let shortcutField = ShortcutField(keyCode: Settings.hotKeyCode,
                                          carbonMods: Settings.hotKeyModifiers)
        shortcutField.onChange = { [weak self] code, mods in
            Settings.hotKeyCode = code
            Settings.hotKeyModifiers = mods
            self?.onHotKeyChange?(code, mods)
        }

        let focusShortcutField = ShortcutField(keyCode: Settings.focusHotKeyCode,
                                               carbonMods: Settings.focusHotKeyModifiers)
        focusShortcutField.onChange = { [weak self] code, mods in
            Settings.focusHotKeyCode = code
            Settings.focusHotKeyModifiers = mods
            self?.onFocusHotKeyChange?(code, mods)
        }

        let dictationShortcutField = ShortcutField(keyCode: Settings.dictationHotKeyCode,
                                                   carbonMods: Settings.dictationHotKeyModifiers)
        dictationShortcutField.onChange = { [weak self] code, mods in
            Settings.dictationHotKeyCode = code
            Settings.dictationHotKeyModifiers = mods
            self?.onDictationHotKeyChange?(code, mods)
        }

        let transformShortcutField = ShortcutField(keyCode: Settings.transformHotKeyCode,
                                                   carbonMods: Settings.transformHotKeyModifiers)
        transformShortcutField.onChange = { [weak self] code, mods in
            Settings.transformHotKeyCode = code
            Settings.transformHotKeyModifiers = mods
            self?.onTransformHotKeyChange?(code, mods)
        }

        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.addItems(withTitles: ["Español", "English"])
        languagePopup.selectItem(at: Settings.language == .spanish ? 0 : 1)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        let slider = NSSlider(value: Settings.scale, minValue: 0.7, maxValue: 1.6,
                              target: self, action: #selector(scaleChanged(_:)))
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        scaleLabel = makeLabel(scaleText(Settings.scale))

        // Live preview while dragging: updating the panel's alphaValue is
        // cheap, unlike scale which rebuilds the panel.
        let opacitySlider = NSSlider(value: Settings.opacity, minValue: 0.3, maxValue: 1.0,
                                     target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.isContinuous = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        opacityLabel = makeLabel(scaleText(Settings.opacity))

        enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopup.addItems(withTitles: ["Apple (sistema)", "Ollama (localhost)", "Desactivado"])
        let engineIndex = ["system": 0, "ollama": 1, "off": 2][Settings.completionEngine] ?? 0
        enginePopup.selectItem(at: engineIndex)
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)

        ollamaModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ollamaModelPopup.addItem(withTitle: Settings.ollamaModel)
        ollamaModelPopup.target = self
        ollamaModelPopup.action = #selector(ollamaModelChanged)
        ollamaModelPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        ollamaModelPopup.isEnabled = false

        dictationModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let dictationModels = [
            ("Base — ligero", "base"),
            ("Small — equilibrado", "small"),
            ("Large v3 Turbo — máxima calidad", "large-v3-v20240930_626MB")
        ]
        for (title, value) in dictationModels {
            dictationModelPopup.addItem(withTitle: title)
            dictationModelPopup.lastItem?.representedObject = value
        }
        let selectedDictationIndex = dictationModels.firstIndex {
            $0.1 == Settings.dictationModel
        } ?? 1
        dictationModelPopup.selectItem(at: selectedDictationIndex)
        dictationModelPopup.target = self
        dictationModelPopup.action = #selector(dictationModelChanged)

        dictationLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let dictationLanguages: [(String, DictationLanguage)] = [
            ("Automático — detecta al hablar", .automatic),
            ("Español", .spanish),
            ("English", .english)
        ]
        for (title, value) in dictationLanguages {
            dictationLanguagePopup.addItem(withTitle: title)
            dictationLanguagePopup.lastItem?.representedObject = value.rawValue
        }
        let selectedDictationLanguage = dictationLanguages.firstIndex {
            $0.1 == Settings.dictationLanguage
        } ?? 0
        dictationLanguagePopup.selectItem(at: selectedDictationLanguage)
        dictationLanguagePopup.target = self
        dictationLanguagePopup.action = #selector(dictationLanguageChanged)

        hoverCheck = NSButton(checkboxWithTitle: "modo arrastre ∿ (toque inicia, toque termina)",
                              target: self, action: #selector(hoverGlideChanged(_:)))
        hoverCheck.state = Settings.hoverGlide ? .on : .off

        let composerCheck = NSButton(checkboxWithTitle: "componer en el panel e insertar con ↪ / ⏎",
                                     target: self, action: #selector(composerModeChanged(_:)))
        composerCheck.state = Settings.composerMode ? .on : .off

        let surroundingCheck = NSButton(checkboxWithTitle: "leer texto visible alrededor del campo (auditable en la consola)",
                                        target: self, action: #selector(surroundingContextChanged(_:)))
        surroundingCheck.state = Settings.surroundingContextEnabled ? .on : .off

        let grid = NSGridView(views: [
            [makeLabel("Atajo mostrar/ocultar:"), shortcutField],
            [makeLabel("Atajo escribir en borrador:"), focusShortcutField],
            [makeLabel("Atajo dictado (mantener):"), dictationShortcutField],
            [makeLabel("Atajo transformar/instrucción:"), transformShortcutField],
            [makeLabel("Idioma:"), languagePopup],
            [makeLabel("Tamaño del teclado:"), slider, scaleLabel],
            [makeLabel("Opacidad del teclado:"), opacitySlider, opacityLabel],
            [makeLabel("Área de borrador:"), composerCheck],
            [makeLabel("Glide sin clic:"), hoverCheck],
            [makeLabel("Completado IA (✦):"), enginePopup],
            [makeLabel("Modelo de Ollama:"), ollamaModelPopup],
            [makeLabel("Modelo de dictado:"), dictationModelPopup],
            [makeLabel("Idioma del dictado:"), dictationLanguagePopup],
            [makeLabel("Contexto para instrucciones:"), surroundingCheck]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let hint = makeLabel("El atajo funciona en todo el sistema. Los cambios se guardan al instante.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        // User dictionary: view and edit the learned words (one per line).
        let dictLabel = makeLabel("Diccionario propio (una palabra por línea):")
        dictLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let dictScroll = NSTextView.scrollableTextView()
        dictionaryView = (dictScroll.documentView as! NSTextView)
        dictionaryView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        dictScroll.translatesAutoresizingMaskIntoConstraints = false
        dictScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        dictScroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        dictScroll.borderType = .bezelBorder

        let saveButton = NSButton(title: "Guardar diccionario", target: self,
                                  action: #selector(saveDictionary))

        let stack = NSStackView(views: [grid, hint, dictLabel, dictScroll, saveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])

        if OllamaModelCatalog.isSelectorEnabled(for: Settings.completionEngine) {
            reloadOllamaModels()
        }
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13)
        return l
    }

    private func scaleText(_ v: Double) -> String { "\(Int(round(v * 100))) %" }

    @objc private func languageChanged() {
        let lang: Language = languagePopup.indexOfSelectedItem == 0 ? .spanish : .english
        Settings.language = lang
        onLanguageChange?(lang)
    }

    @objc private func engineChanged() {
        let engines = ["system", "ollama", "off"]
        Settings.completionEngine = engines[enginePopup.indexOfSelectedItem]
        if OllamaModelCatalog.isSelectorEnabled(for: Settings.completionEngine) {
            reloadOllamaModels()
        } else {
            ollamaModelsTask?.cancel()
            showSavedOllamaModel(enabled: false)
        }
        onCompletionEngineChange?()
    }

    @objc private func ollamaModelChanged() {
        guard let name = ollamaModelPopup.selectedItem?.representedObject as? String else { return }
        Settings.ollamaModel = name
        onCompletionEngineChange?()
    }

    @objc private func dictationModelChanged() {
        guard let model = dictationModelPopup.selectedItem?.representedObject as? String else { return }
        Settings.dictationModel = model
        onDictationModelChange?()
    }

    @objc private func dictationLanguageChanged() {
        guard let rawValue = dictationLanguagePopup.selectedItem?.representedObject as? String,
              let language = DictationLanguage(rawValue: rawValue) else { return }
        Settings.dictationLanguage = language
    }

    private func reloadOllamaModels() {
        ollamaModelsTask?.cancel()
        ollamaModelPopup.removeAllItems()
        ollamaModelPopup.addItem(withTitle: "Cargando modelos…")
        ollamaModelPopup.isEnabled = false
        ollamaModelPopup.toolTip = nil

        ollamaModelsTask = Task { [weak self] in
            do {
                let models = try await OllamaModelCatalog.fetch()
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.showOllamaModels(models) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.ollamaModelPopup.removeAllItems()
                    self?.ollamaModelPopup.addItem(withTitle: "Ollama no disponible")
                    self?.ollamaModelPopup.isEnabled = false
                    self?.ollamaModelPopup.toolTip = error.localizedDescription
                }
            }
        }
    }

    private func showOllamaModels(_ models: [String]) {
        ollamaModelPopup.removeAllItems()
        guard !models.isEmpty else {
            ollamaModelPopup.addItem(withTitle: "Sin modelos instalados")
            ollamaModelPopup.isEnabled = false
            return
        }

        for model in models {
            ollamaModelPopup.addItem(withTitle: model)
            ollamaModelPopup.lastItem?.representedObject = model
        }
        let selectedModel = models.contains(Settings.ollamaModel) ? Settings.ollamaModel : models[0]
        ollamaModelPopup.selectItem(withTitle: selectedModel)
        ollamaModelPopup.isEnabled = true
        if selectedModel != Settings.ollamaModel {
            Settings.ollamaModel = selectedModel
            onCompletionEngineChange?()
        }
    }

    private func showSavedOllamaModel(enabled: Bool) {
        ollamaModelPopup.removeAllItems()
        ollamaModelPopup.addItem(withTitle: Settings.ollamaModel)
        ollamaModelPopup.lastItem?.representedObject = Settings.ollamaModel
        ollamaModelPopup.isEnabled = enabled
        ollamaModelPopup.toolTip = nil
    }

    @objc private func composerModeChanged(_ sender: NSButton) {
        Settings.composerMode = sender.state == .on
        onComposerModeChange?(Settings.composerMode)
    }

    @objc private func surroundingContextChanged(_ sender: NSButton) {
        Settings.surroundingContextEnabled = sender.state == .on
    }

    @objc private func hoverGlideChanged(_ sender: NSButton) {
        Settings.hoverGlide = sender.state == .on
        onHoverGlideChange?(Settings.hoverGlide)
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        let v = (sender.doubleValue * 20).rounded() / 20 // steps of 0.05
        Settings.scale = v
        scaleLabel.stringValue = scaleText(v)
        onScaleChange?(v)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let v = (sender.doubleValue * 20).rounded() / 20 // steps of 0.05
        Settings.opacity = v
        opacityLabel.stringValue = scaleText(v)
        onOpacityChange?(v)
    }

    /// Keep the popup in sync when the language is changed from the keyboard itself.
    func reflectLanguage(_ lang: Language) {
        languagePopup?.selectItem(at: lang == .spanish ? 0 : 1)
    }

    func setUserWords(_ words: [String]) {
        dictionaryView?.string = words.joined(separator: "\n")
    }

    /// Keep the checkbox in sync when the mode is toggled from the keyboard.
    func reflectHoverGlide(_ enabled: Bool) {
        hoverCheck?.state = enabled ? .on : .off
    }

    @objc private func saveDictionary() {
        let words = dictionaryView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onUserDictionaryChange?(words)
    }
}
