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

    private var scaleLabel: NSTextField!
    private var languagePopup: NSPopUpButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
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

        let grid = NSGridView(views: [
            [makeLabel("Atajo mostrar/ocultar:"), shortcutField],
            [makeLabel("Idioma:"), languagePopup],
            [makeLabel("Tamaño del teclado:"), slider, scaleLabel]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let hint = makeLabel("El atajo funciona en todo el sistema. Los cambios se guardan al instante.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [grid, hint])
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
}
