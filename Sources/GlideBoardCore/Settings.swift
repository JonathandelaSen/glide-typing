import AppKit
import Carbon

enum DictationLanguage: String, CaseIterable {
    case automatic = "auto"
    case spanish = "es"
    case english = "en"

    /// `nil` asks WhisperKit to identify the spoken language rather than
    /// coupling dictation to the keyboard's visual ES/EN layout.
    var whisperLanguage: String? {
        self == .automatic ? nil : rawValue
    }
}

/// One optional per-action global shortcut, keyed by `NumaActionID.rawValue`
/// in `Settings.actionShortcuts`. Defined here so the settings component
/// stays self-contained for the shell contract harnesses.
struct ActionShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

/// Rejects a shortcut that another Numa action already uses.
enum ShortcutConflicts {
    static func conflict(keyCode: UInt32, modifiers: UInt32,
                         among existing: [(name: String, keyCode: UInt32, modifiers: UInt32)])
        -> String?
    {
        existing.first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.name
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Hotkey to show/hide the keyboard (Carbon key code + modifiers).
    static var hotKeyCode: UInt32 {
        get { (defaults.object(forKey: "hotKeyCode") as? NSNumber)?.uint32Value ?? UInt32(kVK_ANSI_G) }
        set { defaults.set(NSNumber(value: newValue), forKey: "hotKeyCode") }
    }

    static var hotKeyModifiers: UInt32 {
        get { (defaults.object(forKey: "hotKeyModifiers") as? NSNumber)?.uint32Value ?? UInt32(cmdKey | optionKey) }
        set { defaults.set(NSNumber(value: newValue), forKey: "hotKeyModifiers") }
    }

    /// Hotkey to show the keyboard and focus its composer.
    static var focusHotKeyCode: UInt32 {
        get { (defaults.object(forKey: "focusHotKeyCode") as? NSNumber)?.uint32Value ?? UInt32(kVK_ANSI_G) }
        set { defaults.set(NSNumber(value: newValue), forKey: "focusHotKeyCode") }
    }

    static var focusHotKeyModifiers: UInt32 {
        get {
            (defaults.object(forKey: "focusHotKeyModifiers") as? NSNumber)?.uint32Value
                ?? UInt32(cmdKey | optionKey | shiftKey)
        }
        set { defaults.set(NSNumber(value: newValue), forKey: "focusHotKeyModifiers") }
    }

    /// Hotkey to transform the selection of the focused app (Plan A).
    static var transformHotKeyCode: UInt32 {
        get { (defaults.object(forKey: "transformHotKeyCode") as? NSNumber)?.uint32Value ?? UInt32(kVK_ANSI_T) }
        set { defaults.set(NSNumber(value: newValue), forKey: "transformHotKeyCode") }
    }

    static var transformHotKeyModifiers: UInt32 {
        get { (defaults.object(forKey: "transformHotKeyModifiers") as? NSNumber)?.uint32Value ?? UInt32(cmdKey | optionKey) }
        set { defaults.set(NSNumber(value: newValue), forKey: "transformHotKeyModifiers") }
    }

    /// Hotkey to send the composer draft to the focused app.
    static var sendHotKeyCode: UInt32 {
        get { (defaults.object(forKey: "sendHotKeyCode") as? NSNumber)?.uint32Value ?? UInt32(kVK_Return) }
        set { defaults.set(NSNumber(value: newValue), forKey: "sendHotKeyCode") }
    }

    static var sendHotKeyModifiers: UInt32 {
        get { (defaults.object(forKey: "sendHotKeyModifiers") as? NSNumber)?.uint32Value ?? UInt32(cmdKey) }
        set { defaults.set(NSNumber(value: newValue), forKey: "sendHotKeyModifiers") }
    }

    /// Push-to-talk shortcut for local WhisperKit dictation.
    static var dictationHotKeyCode: UInt32 {
        get { (defaults.object(forKey: "dictationHotKeyCode") as? NSNumber)?.uint32Value ?? UInt32(kVK_Space) }
        set { defaults.set(NSNumber(value: newValue), forKey: "dictationHotKeyCode") }
    }

    static var dictationHotKeyModifiers: UInt32 {
        get {
            (defaults.object(forKey: "dictationHotKeyModifiers") as? NSNumber)?.uint32Value
                ?? UInt32(controlKey | optionKey)
        }
        set { defaults.set(NSNumber(value: newValue), forKey: "dictationHotKeyModifiers") }
    }

    /// Toggle shortcut for hands-free dictation. This is deliberately stored
    /// separately from the existing press/release push-to-talk shortcut.
    static var handsFreeDictationHotKeyCode: UInt32 {
        get {
            (defaults.object(forKey: "handsFreeDictationHotKeyCode") as? NSNumber)?.uint32Value
                ?? UInt32(kVK_ANSI_L)
        }
        set { defaults.set(NSNumber(value: newValue), forKey: "handsFreeDictationHotKeyCode") }
    }

    static var handsFreeDictationHotKeyModifiers: UInt32 {
        get {
            (defaults.object(forKey: "handsFreeDictationHotKeyModifiers") as? NSNumber)?.uint32Value
                ?? UInt32(optionKey)
        }
        set { defaults.set(NSNumber(value: newValue), forKey: "handsFreeDictationHotKeyModifiers") }
    }

    /// Core ML model downloaded by WhisperKit on first use.
    static var dictationModel: String {
        get { defaults.string(forKey: "dictationModel") ?? "small" }
        set { defaults.set(newValue, forKey: "dictationModel") }
    }

    /// WhisperKit model used only by always-on voice attention. Dictation has
    /// its own model preference above and changing either must not affect the
    /// other pipeline.
    static var attentionModelID: String {
        get { defaults.string(forKey: "attentionModelID") ?? "tiny" }
        set { defaults.set(newValue, forKey: "attentionModelID") }
    }

    /// User-configurable voice commands (action → trigger phrase). Falls back
    /// to the defaults when the stored payload is missing or unreadable, and
    /// never persists an empty list.
    static var voiceCommands: [VoiceCommandSetting] {
        get {
            guard let data = defaults.data(forKey: "voiceCommands"),
                  let decoded = try? JSONDecoder().decode([VoiceCommandSetting].self,
                                                          from: data),
                  !decoded.isEmpty else { return VoiceCommandSetting.defaults }
            return decoded
        }
        set {
            let commands = newValue.isEmpty ? VoiceCommandSetting.defaults : newValue
            guard let data = try? JSONEncoder().encode(commands) else { return }
            defaults.set(data, forKey: "voiceCommands")
        }
    }

    /// Seconds of continuous silence that end a hands-free dictation.
    /// Generous by default so thinking pauses don't cut the recording.
    static var handsFreeTrailingSilenceSeconds: Double {
        get {
            guard let value = defaults.object(forKey: "handsFreeTrailingSilenceSeconds")
                    as? Double else { return 3.5 }
            return min(8, max(1.5, value))
        }
        set { defaults.set(min(8, max(1.5, newValue)),
                           forKey: "handsFreeTrailingSilenceSeconds") }
    }

    /// Volume for Numa's activation/finish chimes, 0…1.
    static var numaSoundVolume: Double {
        get {
            guard let value = defaults.object(forKey: "numaSoundVolume") as? Double
            else { return 0.5 }
            return min(1, max(0, value))
        }
        set { defaults.set(min(1, max(0, newValue)), forKey: "numaSoundVolume") }
    }

    static var numaSoundTheme: NumaSoundTheme {
        get {
            NumaSoundTheme(rawValue: defaults.string(forKey: "numaSoundTheme") ?? "")
                ?? .crystal
        }
        set { defaults.set(newValue.rawValue, forKey: "numaSoundTheme") }
    }

    /// Spoken language is independent from the keyboard layout. Automatic is
    /// the useful default for bilingual dictation and pasted technical terms.
    static var dictationLanguage: DictationLanguage {
        get { DictationLanguage(rawValue: defaults.string(forKey: "dictationLanguage") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "dictationLanguage") }
    }

    /// Plan B: opt-in to reading visible text around the focused field (AX)
    /// as context for free-instruction generation. Off by default — it reads
    /// screen content beyond the field itself.
    static var surroundingContextEnabled: Bool {
        get { defaults.object(forKey: "surroundingContextEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "surroundingContextEnabled") }
    }

    /// Bundle-id prefixes never read for surrounding context (password
    /// managers, banking…).
    static var surroundingContextExcludedApps: [String] {
        get {
            defaults.stringArray(forKey: "surroundingContextExcludedApps")
                ?? ["com.1password", "com.agilebits", "com.apple.Passwords", "com.lastpass"]
        }
        set { defaults.set(newValue, forKey: "surroundingContextExcludedApps") }
    }

    /// Recent free instructions (prompt-anywhere), newest first.
    static var promptHistory: [String] {
        get { defaults.stringArray(forKey: "promptHistory") ?? [] }
        set { defaults.set(Array(newValue.prefix(20)), forKey: "promptHistory") }
    }

    static var language: Language {
        get { Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .spanish }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    /// AI phrase-completion engine: "system" (Apple), "ollama", or "off".
    static var completionEngine: String {
        get { defaults.string(forKey: "completionEngine") ?? "system" }
        set { defaults.set(newValue, forKey: "completionEngine") }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: "ollamaModel") ?? "gemma3:1b" }
        set { defaults.set(newValue, forKey: "ollamaModel") }
    }

    /// Composer mode: compose text in the panel, insert into the app on demand.
    static var composerMode: Bool {
        get { defaults.object(forKey: "composerMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "composerMode") }
    }

    /// Glide by hovering: pause on a letter to start, pause again to commit.
    static var hoverGlide: Bool {
        get { defaults.object(forKey: "hoverGlide") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hoverGlide") }
    }

    /// Keyboard size multiplier.
    static var scale: Double {
        get {
            let v = defaults.double(forKey: "scale")
            return v == 0 ? 1.0 : min(max(v, 0.7), 1.6)
        }
        set { defaults.set(newValue, forKey: "scale") }
    }

    /// Keyboard panel opacity (0.3–1.0).
    static var opacity: Double {
        get {
            let v = defaults.double(forKey: "opacity")
            return v == 0 ? 1.0 : min(max(v, 0.3), 1.0)
        }
        set { defaults.set(newValue, forKey: "opacity") }
    }

    /// Double-Option launcher for the command palette.
    static var doubleOptionPaletteEnabled: Bool {
        get { defaults.object(forKey: "doubleOptionPaletteEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "doubleOptionPaletteEnabled") }
    }

    /// Seconds allowed between the two Option releases. A configurable
    /// constant without UI for now.
    static var doubleOptionWindowSeconds: Double {
        get {
            guard let value = defaults.object(forKey: "doubleOptionWindowSeconds")
                    as? Double else { return 0.4 }
            return min(0.8, max(0.2, value))
        }
        set { defaults.set(min(0.8, max(0.2, newValue)),
                           forKey: "doubleOptionWindowSeconds") }
    }

    /// Optional per-action global shortcuts, keyed by `NumaActionID.rawValue`.
    /// Every action starts unset; only user-configured entries are stored.
    static var actionShortcuts: [String: ActionShortcut] {
        get {
            guard let data = defaults.data(forKey: "actionShortcuts"),
                  let decoded = try? JSONDecoder().decode([String: ActionShortcut].self,
                                                          from: data) else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "actionShortcuts")
        }
    }

    /// Action IDs recently executed from the palette, most recent first.
    static var paletteRecents: [String] {
        get { defaults.stringArray(forKey: "paletteRecents") ?? [] }
        set { defaults.set(Array(newValue.prefix(8)), forKey: "paletteRecents") }
    }
}

// MARK: - Shortcut helpers

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    return mods
}

func shortcutDescription(keyCode: UInt32, modifiers: UInt32) -> String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
    return s + keyName(for: keyCode)
}

func modifierFlags(fromCarbon modifiers: UInt32) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
    if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
    if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
    return flags
}

/// Character usable as an `NSMenuItem.keyEquivalent` for a Carbon key code,
/// so configurable global hotkeys render right-aligned in menus like native
/// shortcuts. `nil` when the key has no menu representation.
func keyEquivalentCharacter(for keyCode: UInt32) -> String? {
    switch keyCode {
    case 49: return " "
    case 36: return "\r"
    case 48: return "\t"
    case 51: return "\u{08}"
    case 53: return "\u{1B}"
    case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
    case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
    case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
    default:
        let name = keyName(for: keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              scalar.isASCII else { return nil }
        return name.lowercased()
    }
}

func keyName(for keyCode: UInt32) -> String {
    let names: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        49: "Espacio", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
    return names[keyCode] ?? "key\(keyCode)"
}
