import Foundation
@testable import GlideBoardCore

@MainActor
func voiceAttentionChecks() async {
    let c = Checks.shared
    c.begin("Voice attention")

    await c.test("default descriptor is centralized and uses WhisperKit tiny") {
        let descriptor = VoiceAttentionDescriptor.default(modelID: "tiny")
        try expectEqual(descriptor.backend, .whisperKit)
        try expectEqual(descriptor.modelID, "tiny")
        try expectEqual(descriptor.language, "es")
        try expectEqual(descriptor.sampleRate, 16_000)
        try expectEqual(descriptor.ringCapacitySamples, 96_000)
        try expectTrue(descriptor.windowSamples > descriptor.hopSamples)
    }

    await c.test("installed WhisperKit model identifiers include tiny and base") {
        try expectTrue(VoiceAttentionModelID.supported.contains("tiny"))
        try expectTrue(VoiceAttentionModelID.supported.contains("base"))
        try expectFalse(VoiceAttentionModelID.isSupported("tiny.en"),
                        "attention must use a multilingual model")
        try expectFalse(VoiceAttentionModelID.isSupported("invented"))
    }

    await c.test("wake matching requires the Numa lexical token") {
        try expectTrue(VoiceAttentionIntentMatcher.containsWakeWord("Numa."))
        try expectTrue(VoiceAttentionIntentMatcher.containsWakeWord("hola, Núma"))
        try expectFalse(VoiceAttentionIntentMatcher.containsWakeWord("número"))
        try expectFalse(VoiceAttentionIntentMatcher.containsWakeWord("luma"))
    }

    await c.test("command matching accepts only graba audio") {
        try expectTrue(VoiceAttentionIntentMatcher.containsCommand("graba audio"))
        try expectTrue(VoiceAttentionIntentMatcher.containsCommand("Numa, graba audio, mañana"))
        try expectFalse(VoiceAttentionIntentMatcher.containsCommand("grabar audio"))
        try expectFalse(VoiceAttentionIntentMatcher.containsCommand("empieza a grabar"))
        try expectFalse(VoiceAttentionIntentMatcher.containsCommand("graba el audio"))
        try expectFalse(VoiceAttentionIntentMatcher.containsCommand("no graba audio"))
        try expectFalse(VoiceAttentionIntentMatcher.containsCommand("por favor graba audio"))
        let timed = AttentionTranscript(
            text: " graba audio",
            words: [
                AttentionWord(text: " graba", start: 0.1, end: 0.4,
                              textRangeUTF16: 0..<6),
                AttentionWord(text: " audio", start: 0.45, end: 0.8,
                              textRangeUTF16: 6..<12),
            ]
        )
        try expectEqual(VoiceAttentionIntentMatcher.commandEndTime(timed), 0.8)
    }

    await c.test("prefix trimmer removes only the timestamped leading command") {
        let transcript = DictationTranscript(
            text: "Numa, graba audio, mañana audio espacial",
            words: [
                TranscribedWord(text: "Numa", start: 0.0, end: 0.25, textRangeUTF16: 0..<4),
                TranscribedWord(text: "graba", start: 0.28, end: 0.55, textRangeUTF16: 6..<11),
                TranscribedWord(text: "audio", start: 0.58, end: 0.88, textRangeUTF16: 12..<17),
                TranscribedWord(text: "mañana", start: 0.92, end: 1.30, textRangeUTF16: 19..<25),
                TranscribedWord(text: "audio", start: 1.34, end: 1.62, textRangeUTF16: 26..<31),
                TranscribedWord(text: "espacial", start: 1.64, end: 2.0, textRangeUTF16: 32..<40),
            ]
        )
        let result = VoiceCommandPrefixTrimmer.trim(
            transcript,
            wakeWord: "numa",
            estimatedCommandEnd: 0.90
        )
        try expectEqual(result, .success("mañana audio espacial"))
    }

    await c.test("prefix trimmer fails closed for unsafe ranges or timing") {
        let late = DictationTranscript(
            text: "graba audio mañana",
            words: [
                TranscribedWord(text: "graba", start: 0, end: 0.4, textRangeUTF16: 0..<5),
                TranscribedWord(text: "audio", start: 0.5, end: 1.4, textRangeUTF16: 6..<11),
                TranscribedWord(text: "mañana", start: 1.5, end: 1.9, textRangeUTF16: 12..<18),
            ]
        )
        try expectEqual(VoiceCommandPrefixTrimmer.trim(
            late, wakeWord: "numa", estimatedCommandEnd: 1.0), .unsafe)

        let overlap = DictationTranscript(
            text: "graba audio",
            words: [
                TranscribedWord(text: "graba", start: 0, end: 0.4, textRangeUTF16: 0..<7),
                TranscribedWord(text: "audio", start: 0.5, end: 0.8, textRangeUTF16: 6..<11),
            ]
        )
        try expectEqual(VoiceCommandPrefixTrimmer.trim(
            overlap, wakeWord: "numa", estimatedCommandEnd: 0.8), .unsafe)
    }
}
