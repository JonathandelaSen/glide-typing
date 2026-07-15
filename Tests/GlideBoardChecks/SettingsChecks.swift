import AppKit
import Carbon
@testable import GlideBoardCore

/// These run against this process's own defaults domain (wiped at startup in
/// Main.swift) — never against the real app's preferences.
@MainActor
func settingsChecks() async {
    let c = Checks.shared
    c.begin("Settings")

    await c.test("hotkey defaults are ⌘⌥G / ⌘⌥⇧G / ⌘⌥T / ⌃⌥Space") {
        try expectEqual(Settings.hotKeyCode, UInt32(kVK_ANSI_G))
        try expectEqual(Settings.hotKeyModifiers, UInt32(cmdKey | optionKey))
        try expectEqual(Settings.focusHotKeyModifiers, UInt32(cmdKey | optionKey | shiftKey))
        try expectEqual(Settings.transformHotKeyCode, UInt32(kVK_ANSI_T))
        try expectEqual(Settings.dictationHotKeyCode, UInt32(kVK_Space))
        try expectEqual(Settings.dictationHotKeyModifiers, UInt32(controlKey | optionKey))
        try expectEqual(Settings.dictationLanguage, .automatic)
        try expectEqual(Settings.handsFreeDictationHotKeyCode, UInt32(kVK_ANSI_L))
        try expectEqual(Settings.handsFreeDictationHotKeyModifiers, UInt32(optionKey))
        try expectEqual(Settings.attentionModelID, "tiny")
        try expectEqual(Settings.numaSoundTheme, .crystal)
    }

    await c.test("values round-trip through defaults") {
        Settings.hotKeyCode = 42
        try expectEqual(Settings.hotKeyCode, 42)
        Settings.language = .english
        try expectEqual(Settings.language, .english)
        Settings.language = .spanish
        Settings.dictationLanguage = .english
        try expectEqual(Settings.dictationLanguage.whisperLanguage, "en")
        Settings.dictationLanguage = .automatic
        try expectNil(Settings.dictationLanguage.whisperLanguage)

        let pttCode = Settings.dictationHotKeyCode
        let pttModifiers = Settings.dictationHotKeyModifiers
        Settings.handsFreeDictationHotKeyCode = UInt32(kVK_ANSI_M)
        Settings.handsFreeDictationHotKeyModifiers = UInt32(cmdKey)
        Settings.attentionModelID = "base"
        try expectEqual(Settings.handsFreeDictationHotKeyCode, UInt32(kVK_ANSI_M))
        try expectEqual(Settings.handsFreeDictationHotKeyModifiers, UInt32(cmdKey))
        try expectEqual(Settings.attentionModelID, "base")
        Settings.numaSoundTheme = .organic
        try expectEqual(Settings.numaSoundTheme, .organic)
        try expectEqual(Settings.dictationHotKeyCode, pttCode)
        try expectEqual(Settings.dictationHotKeyModifiers, pttModifiers)
    }

    await c.test("scale clamps to its usable range") {
        Settings.scale = 5
        try expectEqual(Settings.scale, 1.6)
        Settings.scale = 0.1
        try expectEqual(Settings.scale, 0.7)
        Settings.scale = 1.0
    }

    await c.test("opacity clamps and defaults to fully opaque") {
        Settings.opacity = 0.05
        try expectEqual(Settings.opacity, 0.3)
        Settings.opacity = 2
        try expectEqual(Settings.opacity, 1.0)
    }

    await c.test("prompt history keeps at most 20 entries") {
        Settings.promptHistory = (0..<30).map { "instrucción \($0)" }
        try expectEqual(Settings.promptHistory.count, 20)
        try expectEqual(Settings.promptHistory.first, "instrucción 0")
    }

    await c.test("password managers are excluded from surrounding context by default") {
        try expectFalse(Settings.surroundingContextEnabled, "context reading must be opt-in")
        try expectTrue(Settings.surroundingContextExcludedApps.contains("com.1password"))
    }

    await c.test("voice commands persist and never decay to an empty list") {
        let original = UserDefaults.standard.data(forKey: "voiceCommands")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "voiceCommands")
            } else {
                UserDefaults.standard.removeObject(forKey: "voiceCommands")
            }
        }
        UserDefaults.standard.removeObject(forKey: "voiceCommands")
        try expectEqual(Settings.voiceCommands, VoiceCommandSetting.defaults)

        var commands = Settings.voiceCommands
        commands[0].phrase = "Numa, dicta"
        Settings.voiceCommands = commands
        try expectEqual(Settings.voiceCommands[0].phrase, "Numa, dicta")

        Settings.voiceCommands = []
        try expectEqual(Settings.voiceCommands, VoiceCommandSetting.defaults)
    }

    await c.test("carbonModifiers translates AppKit flags") {
        try expectEqual(carbonModifiers(from: [.command, .option]),
                        UInt32(cmdKey | optionKey))
        try expectEqual(carbonModifiers(from: []), 0)
        try expectEqual(carbonModifiers(from: [.control, .shift]),
                        UInt32(controlKey | shiftKey))
    }

    await c.test("shortcutDescription orders modifiers ⌃⌥⇧⌘ and names keys") {
        try expectEqual(shortcutDescription(keyCode: UInt32(kVK_ANSI_G),
                                            modifiers: UInt32(cmdKey | optionKey)),
                        "⌥⌘G")
        try expectEqual(shortcutDescription(keyCode: UInt32(kVK_Space),
                                            modifiers: UInt32(controlKey)),
                        "⌃Espacio")
        try expectEqual(keyName(for: 9999), "key9999")
    }
}
