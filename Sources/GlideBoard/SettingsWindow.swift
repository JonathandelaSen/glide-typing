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
    var onLanguageChange: ((Language) -> Void)?
    var onScaleChange: ((Double) -> Void)?
    var onCompletionEngineChange: (() -> Void)?
    var onHoverGlideChange: ((Bool) -> Void)?
    var onUserDictionaryChange: (([String]) -> Void)?
    private var dictionaryView: NSTextView!
    private var hoverCheck: NSButton!

    private var scaleLabel: NSTextField!
    private var languagePopup: NSPopUpButton!
    private var enginePopup: NSPopUpButton!
    private var ollamaModelField: NSTextField!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
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

        enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopup.addItems(withTitles: ["Apple (sistema)", "Ollama (localhost)", "Desactivado"])
        let engineIndex = ["system": 0, "ollama": 1, "off": 2][Settings.completionEngine] ?? 0
        enginePopup.selectItem(at: engineIndex)
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)

        ollamaModelField = NSTextField(string: Settings.ollamaModel)
        ollamaModelField.placeholderString = "p. ej. qwen3.5:4b"
        ollamaModelField.target = self
        ollamaModelField.action = #selector(ollamaModelChanged)
        ollamaModelField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        ollamaModelField.isEnabled = Settings.completionEngine == "ollama"

        hoverCheck = NSButton(checkboxWithTitle: "modo arrastre ∿ (toque inicia, toque termina)",
                              target: self, action: #selector(hoverGlideChanged(_:)))
        hoverCheck.state = Settings.hoverGlide ? .on : .off

        let grid = NSGridView(views: [
            [makeLabel("Atajo mostrar/ocultar:"), shortcutField],
            [makeLabel("Idioma:"), languagePopup],
            [makeLabel("Tamaño del teclado:"), slider, scaleLabel],
            [makeLabel("Glide sin clic:"), hoverCheck],
            [makeLabel("Completado IA (✦):"), enginePopup],
            [makeLabel("Modelo de Ollama:"), ollamaModelField]
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
        ollamaModelField.isEnabled = Settings.completionEngine == "ollama"
        onCompletionEngineChange?()
    }

    @objc private func ollamaModelChanged() {
        let name = ollamaModelField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            Settings.ollamaModel = name
            onCompletionEngineChange?()
        }
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
