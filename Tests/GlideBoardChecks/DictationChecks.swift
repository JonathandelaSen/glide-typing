import Foundation
import Carbon
@testable import GlideBoardCore

private final class DictationTranscriberSpy: DictationTranscribing {
    var calls: [(samples: [Float], language: String?, words: Bool, prompt: String?)] = []
    var transcript = DictationTranscript(text: "", words: [])
    var resume: CheckedContinuation<Void, Never>?

    func transcribe(samples: [Float], language: String?,
                    wordTimestamps: Bool,
                    biasPrompt: String?) async throws -> DictationTranscript {
        calls.append((samples, language, wordTimestamps, biasPrompt))
        if resume != nil {
            await withCheckedContinuation { continuation in resume = continuation }
        }
        return transcript
    }
}

@MainActor
func dictationChecks() async {
    let c = Checks.shared
    c.begin("Dictation")

    await c.test("prepare captures the target once and publishes mode") {
        let transcriber = DictationTranscriberSpy()
        var captured: [DictationSessionID] = []
        var states: [DictationState] = []
        let controller = DictationController(
            transcriber: transcriber,
            language: { "es" },
            willStart: { captured.append($0) },
            deliver: { _, _, completion in completion() },
            stateChanged: { states.append($0) }
        )
        try expectTrue(controller.prepare(sessionID: 10, mode: .pushToTalk,
                                          source: .pushToTalk))
        try expectFalse(controller.prepare(sessionID: 11, mode: .handsFree,
                                           source: .button))
        controller.recordingDidStart(sessionID: 10)
        try expectEqual(captured, [10])
        try expectEqual(states, [.preparing(.pushToTalk), .recording(.pushToTalk)])
    }

    await c.test("stop transcribes a snapshot and waits for AppDelegate completion") {
        let transcriber = DictationTranscriberSpy()
        transcriber.transcript = DictationTranscript(text: "  Hola desde WhisperKit. \n", words: [])
        var delivered: [String] = []
        var finishDelivery: (() -> Void)?
        let controller = DictationController(
            transcriber: transcriber,
            language: { "es" },
            willStart: { _ in },
            deliver: { _, text, completion in
                delivered.append(text)
                finishDelivery = completion
            },
            stateChanged: { _ in }
        )
        _ = controller.prepare(sessionID: 1, mode: .pushToTalk, source: .pushToTalk)
        controller.recordingDidStart(sessionID: 1)
        let task = Task { @MainActor in
            await controller.stop(sessionID: 1, reason: .pushToTalkReleased,
                                  samples: [0.1, 0.2])
        }
        for _ in 0..<20 where controller.state != .delivering(.pushToTalk) {
            await Task.yield()
        }
        try expectEqual(controller.state, .delivering(.pushToTalk))
        try expectEqual(delivered, ["Hola desde WhisperKit."])
        finishDelivery?()
        try expectEqual(await task.value, .delivered)
        try expectEqual(controller.state, .idle)
        try expectEqual(transcriber.calls.count, 1)
        try expectEqual(transcriber.calls[0].language, "es")
        try expectFalse(transcriber.calls[0].words)
        try expectNil(transcriber.calls[0].prompt)
    }

    await c.test("voice sessions deliver plain transcripts without trimming") {
        let transcriber = DictationTranscriberSpy()
        transcriber.transcript = DictationTranscript(text: " mañana tenemos ", words: [])
        // The session audio starts after the command utterance, so the
        // transcript is already pure dictation.
        let context = VoiceCommandContext(
            audioReservationID: 1, commandPhrase: "Numa, graba",
            sessionAudioStartSample: 20_000,
            commandDetectionWindowStartSample: 0,
            commandDetectionWindowEndSample: 20_000,
            estimatedCommandEndSample: 20_000
        )
        var delivered = ""
        let controller = DictationController(
            transcriber: transcriber, language: { "es" }, willStart: { _ in },
            deliver: { _, text, completion in delivered = text; completion() },
            stateChanged: { _ in }
        )
        _ = controller.prepare(sessionID: 2, mode: .handsFree,
                               source: .voiceCommand(context))
        controller.recordingDidStart(sessionID: 2)
        let outcome = await controller.stop(sessionID: 2, reason: .trailingSilence,
                                            samples: [0.1])
        try expectEqual(outcome, .delivered)
        try expectEqual(delivered, "mañana tenemos")
        try expectFalse(transcriber.calls[0].words)
        // Never the command phrase: a Whisper prompt is "already transcribed
        // context" and makes the model omit the matching audio.
        try expectNil(transcriber.calls[0].prompt)
    }

    await c.test("stale session callbacks do not change the active session") {
        let controller = DictationController(
            transcriber: DictationTranscriberSpy(), language: { nil }, willStart: { _ in },
            deliver: { _, _, completion in completion() }, stateChanged: { _ in }
        )
        _ = controller.prepare(sessionID: 4, mode: .handsFree, source: .button)
        controller.recordingDidStart(sessionID: 999)
        controller.cancel(sessionID: 999)
        try expectEqual(controller.state, .preparing(.handsFree))
        controller.cancel(sessionID: 4)
        try expectEqual(controller.state, .idle)
    }

    await c.test("dictation status stays explicit while work is in progress") {
        try expectEqual(DictationState.preparing(.pushToTalk).statusText, "Preparando micrófono…")
        try expectEqual(DictationState.recording(.handsFree).statusText,
                        "Grabando · termina con ⌥L, menú o 🎙")
        try expectEqual(DictationState.transcribing(.handsFree).statusText,
                        "Transcribiendo localmente…")
        try expectNil(DictationState.idle.statusText)
    }

    await c.test("word timings tolerate ASR jitter but reject real jumps") {
        // A few ms of overlap is clamped to a monotonic timeline.
        let jitter = try unwrap(WordTimingSanitizer.sanitize(
            start: 0.95, end: 1.4, previousEnd: 1.0))
        try expectEqual(jitter.start, 1.0)
        try expectEqual(jitter.end, 1.4)
        // Backwards jumps beyond the tolerance are inconsistent transcripts.
        try expectNil(WordTimingSanitizer.sanitize(
            start: 0.2, end: 0.5, previousEnd: 2.0))
        try expectNil(WordTimingSanitizer.sanitize(
            start: 1.0, end: 0.5, previousEnd: 0))
    }

    await c.test("insertion adds a separator only after unspaced draft text") {
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto", existingText: "borrador"),
                        " nuevo texto")
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto", existingText: "borrador "),
                        "nuevo texto")
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto", existingText: "",
                                                replacingSelection: true), "nuevo texto")
        try expectEqual(DictationInsertion.text(transcript: "  ", existingText: "x"), "")
    }

    await c.test("Carbon hotkey events map to press/release phases") {
        try expectEqual(hotKeyPhase(eventKind: UInt32(kEventHotKeyPressed)), .pressed)
        try expectEqual(hotKeyPhase(eventKind: UInt32(kEventHotKeyReleased)), .released)
        try expectNil(hotKeyPhase(eventKind: UInt32(kEventRawKeyDown)))
    }

    await c.test("hotkey routing only claims its own registration") {
        let mine = EventHotKeyID(signature: OSType(0x474C4244), id: 7)
        let same = EventHotKeyID(signature: OSType(0x474C4244), id: 7)
        let otherID = EventHotKeyID(signature: OSType(0x474C4244), id: 8)
        let otherApp = EventHotKeyID(signature: OSType(0x41424344), id: 7)
        try expectEqual(hotKeyRoutingResult(registered: mine, pressed: same), OSStatus(noErr))
        try expectEqual(hotKeyRoutingResult(registered: mine, pressed: otherID),
                        OSStatus(eventNotHandledErr))
        try expectEqual(hotKeyRoutingResult(registered: mine, pressed: otherApp),
                        OSStatus(eventNotHandledErr))
    }

    await c.test("dictation button hit-testing honours the help overlay") {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        try expectTrue(dictationButtonWasPressed(at: CGPoint(x: 12, y: 12),
                                                 buttonRect: rect, helpVisible: false))
        // The tolerance inset accepts near misses…
        try expectTrue(dictationButtonWasPressed(at: CGPoint(x: 8, y: 8),
                                                 buttonRect: rect, helpVisible: false))
        // …but not clicks clearly outside, nor any click while help covers it.
        try expectFalse(dictationButtonWasPressed(at: CGPoint(x: 0, y: 0),
                                                  buttonRect: rect, helpVisible: false))
        try expectFalse(dictationButtonWasPressed(at: CGPoint(x: 12, y: 12),
                                                  buttonRect: rect, helpVisible: true))
    }
}
