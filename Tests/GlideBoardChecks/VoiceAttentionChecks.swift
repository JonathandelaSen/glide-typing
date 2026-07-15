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
        // 10 s: wake window + 3 s command window + command right context +
        // two WhisperKit inference latencies must fit before reservation.
        try expectEqual(descriptor.ringCapacitySamples, 160_000)
        try expectTrue(descriptor.windowSamples > descriptor.hopSamples)
    }

    await c.test("installed WhisperKit model identifiers include tiny and base") {
        try expectTrue(VoiceAttentionModelID.supported.contains("tiny"))
        try expectTrue(VoiceAttentionModelID.supported.contains("base"))
        try expectFalse(VoiceAttentionModelID.isSupported("tiny.en"),
                        "attention must use a multilingual model")
        try expectFalse(VoiceAttentionModelID.isSupported("invented"))
    }

    await c.test("the grammar matches a configured phrase only as prefix") {
        let commands = [VoiceCommandSetting(action: .record, phrase: "Numa, graba")]

        let exact = try unwrap(VoiceCommandGrammar.match(text: "¡Numa, graba!",
                                                         commands: commands))
        try expectEqual(exact.command.action, .record)
        try expectFalse(exact.hasTrailingSpeech)
        // Continuous speech after the command still matches by prefix.
        let continued = try unwrap(VoiceCommandGrammar.match(
            text: "Numa, graba, mañana tenemos", commands: commands))
        try expectEqual(continued.command.action, .record)
        try expectTrue(continued.hasTrailingSpeech)
        // Homophone spelling from the ASR, not a synonym.
        try expectEqual(VoiceCommandGrammar.match(text: "Numa, grava",
                                                  commands: commands)?.command.action,
                        .record)

        // The phrase must start the utterance and be complete.
        for wrong in ["oye, Numa, graba", "Numa", "Numa, grábala", "graba",
                      "graba Numa"] {
            try expectNil(VoiceCommandGrammar.match(text: wrong, commands: commands))
        }

        try expectTrue(VoiceCommandGrammar.mentionsCommandStart("hola, Núma",
                                                                commands: commands))
        try expectFalse(VoiceCommandGrammar.mentionsCommandStart("número",
                                                                 commands: commands))
        try expectFalse(VoiceCommandGrammar.mentionsCommandStart("luma",
                                                                 commands: commands))
    }

    await c.test("the recognizer prompt is built from every configured phrase") {
        let commands = [
            VoiceCommandSetting(action: .record, phrase: "Numa, graba")
        ]
        try expectEqual(VoiceCommandGrammar.biasPrompt(for: commands), "Numa, graba.")
        try expectEqual(VoiceCommandGrammar.tokens(of: "¡Numa, GRABA!"), ["numa", "graba"])
    }

}
