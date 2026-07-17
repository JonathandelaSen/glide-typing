import Foundation

/// Closed set of actions Numa can execute by voice. Adding an action is a
/// code change; the user only configures the phrase that triggers it.
enum VoiceCommandAction: String, Codable, CaseIterable, Sendable {
    case record

    var displayName: String {
        switch self {
        case .record: "Grabar dictado"
        }
    }
}

/// One configurable voice command: a fixed action and the exact phrase that
/// triggers it, spoken as a single utterance ("Numa, graba").
struct VoiceCommandSetting: Codable, Equatable, Sendable {
    let action: VoiceCommandAction
    var phrase: String

    static let defaults: [VoiceCommandSetting] = [
        VoiceCommandSetting(action: .record, phrase: "Numa, graba")
    ]
}

/// Lexical normalization shared by the command grammar and the prefix
/// trimmer. Matching itself lives in VoiceCommandGrammar.
enum VoiceAttentionIntentMatcher {
    static func normalize(_ token: String) -> String {
        let folded = token.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "es_ES"))
        let cleaned = folded.trimmingCharacters(
            in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        )
            .lowercased()
        // "graba" and "grava" are homophones in Spanish; the ASR picks either
        // spelling for the same acoustics. This is spelling tolerance for the
        // canonical command, not a synonym.
        return cleaned == "grava" ? "graba" : cleaned
    }
}

/// Closed command grammar guided by the decoder prompt. Decided 2026-07-15
/// (docs/experiments/numa-wake-word-whisperkit.md): the recognizer is biased
/// towards the configured phrases and an utterance triggers a command only
/// when its words start with one of them.
enum VoiceCommandGrammar {
    /// Normalized lexical tokens of a phrase ("Numa, graba" → ["numa","graba"]).
    static func tokens(of phrase: String) -> [String] {
        phrase.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .map(VoiceAttentionIntentMatcher.normalize)
            .filter { !$0.isEmpty }
    }

    /// Initial prompt for the recognizer: every configured phrase, so the
    /// decoder expects exactly this vocabulary.
    static func biasPrompt(for commands: [VoiceCommandSetting]) -> String {
        commands.map { command in
            let phrase = command.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            return phrase.hasSuffix(".") ? phrase : phrase + "."
        }
        .joined(separator: " ")
    }

    /// Matches an utterance's plain text against the configured commands.
    /// Text-only on purpose: the 9/10 lab battery ran without word
    /// timestamps, and that decode mode transcribes better on tiny. The
    /// command must be the prefix of the utterance; `hasTrailingSpeech`
    /// distinguishes the clean two-phase flow (command, pause, dictation)
    /// from same-breath continuation ("Numa, graba, mañana…").
    static func match(text: String, commands: [VoiceCommandSetting])
        -> (command: VoiceCommandSetting, hasTrailingSpeech: Bool)?
    {
        let heard = tokens(of: text)
        for command in commands {
            let expected = tokens(of: command.phrase)
            guard !expected.isEmpty, heard.count >= expected.count,
                  Array(heard.prefix(expected.count)) == expected else { continue }
            return (command, heard.count > expected.count)
        }
        return nil
    }

    /// True when the utterance at least starts like some command (its first
    /// word matches a command's first word). Drives the "No te he entendido"
    /// feedback without treating unrelated speech as a failed command.
    static func mentionsCommandStart(_ text: String,
                                     commands: [VoiceCommandSetting]) -> Bool
    {
        let firstTokens = Set(commands.compactMap { tokens(of: $0.phrase).first })
        guard !firstTokens.isEmpty else { return false }
        return text.split(whereSeparator: { $0.isWhitespace })
            .map { VoiceAttentionIntentMatcher.normalize(String($0)) }
            .contains { firstTokens.contains($0) }
    }
}
