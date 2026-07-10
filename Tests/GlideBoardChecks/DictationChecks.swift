import Foundation
import Carbon
@testable import GlideBoardCore

private final class DictationEngineSpy: DictationEngine {
    var startCount = 0
    var stopCount = 0
    var cancelCount = 0
    var receivedLanguages: [String?] = []
    var transcript = ""
    var startError: Error?

    func startRecording() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stopRecordingAndTranscribe(language: String?) async throws -> String {
        stopCount += 1
        receivedLanguages.append(language)
        return transcript
    }

    func cancelRecording() {
        cancelCount += 1
    }
}

@MainActor
func dictationChecks() async {
    let c = Checks.shared
    c.begin("Dictation")

    await c.test("press starts recording and publishes the state sequence") {
        let engine = DictationEngineSpy()
        var states: [DictationState] = []
        var targetSnapshots = 0
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            willStart: { targetSnapshots += 1 },
            output: { _ in },
            stateChanged: { states.append($0) }
        )
        await controller.press()
        try expectEqual(engine.startCount, 1)
        try expectEqual(targetSnapshots, 1)
        try expectEqual(controller.state, .recording)
        try expectEqual(states, [.preparing, .recording])
    }

    await c.test("release transcribes in the selected language, trimmed") {
        let engine = DictationEngineSpy()
        engine.transcript = "  Hola desde WhisperKit. \n"
        var output: [String] = []
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            output: { output.append($0) },
            stateChanged: { _ in }
        )
        await controller.press()
        await controller.release()
        try expectEqual(engine.stopCount, 1)
        try expectEqual(engine.receivedLanguages, ["es"])
        try expectEqual(output, ["Hola desde WhisperKit."])
        try expectEqual(controller.state, .idle)
    }

    await c.test("automatic dictation does not force the keyboard language") {
        let engine = DictationEngineSpy()
        engine.transcript = "Hola y thank you"
        var output: [String] = []
        let controller = DictationController(
            engine: engine,
            language: { nil },
            output: { output.append($0) },
            stateChanged: { _ in }
        )
        await controller.press()
        await controller.release()
        try expectEqual(engine.receivedLanguages, [nil])
        try expectEqual(output, ["Hola y thank you"])
    }

    await c.test("long dictations split on silence and auto-detect only when requested") {
        let automatic = DictationDecoding.options(language: nil)
        try expectNil(automatic.language)
        try expectTrue(automatic.detectLanguage)
        try expectEqual(automatic.chunkingStrategy?.rawValue, "vad")

        let spanish = DictationDecoding.options(language: "es")
        try expectEqual(spanish.language, "es")
        try expectFalse(spanish.detectLanguage)
    }

    await c.test("dictation status stays explicit while work is in progress") {
        try expectEqual(DictationState.preparing.statusText, "Preparando micrófono…")
        try expectEqual(DictationState.recording.statusText,
                        "Grabando · termina con el atajo o 🎙")
        try expectEqual(DictationState.transcribing.statusText, "Transcribiendo localmente…")
        try expectNil(DictationState.idle.statusText)
    }

    await c.test("an empty transcript emits nothing") {
        let engine = DictationEngineSpy()
        engine.transcript = " \n "
        var output: [String] = []
        let controller = DictationController(
            engine: engine,
            language: { "en" },
            output: { output.append($0) },
            stateChanged: { _ in }
        )
        await controller.press()
        await controller.release()
        try expectTrue(output.isEmpty)
        try expectEqual(controller.state, .idle)
    }

    await c.test("a failed start cancels the engine and reports failure") {
        let engine = DictationEngineSpy()
        engine.startError = NSError(domain: "mic", code: 1)
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            output: { _ in },
            stateChanged: { _ in }
        )
        await controller.press()
        try expectEqual(engine.cancelCount, 1)
        if case .failed = controller.state {} else {
            throw CheckFailure(message: "expected .failed, got \(controller.state)",
                               location: #fileID)
        }
        // A failed controller accepts a new press.
        engine.startError = nil
        await controller.press()
        try expectEqual(controller.state, .recording)
    }

    await c.test("cancel returns to idle and stops the engine") {
        let engine = DictationEngineSpy()
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            output: { _ in },
            stateChanged: { _ in }
        )
        await controller.press()
        controller.cancel()
        try expectEqual(engine.cancelCount, 1)
        try expectEqual(controller.state, .idle)
    }

    await c.test("insertion adds a separator only after unspaced draft text") {
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto",
                                                existingText: "borrador"),
                        " nuevo texto")
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto",
                                                existingText: "borrador "),
                        "nuevo texto")
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto",
                                                existingText: ""),
                        "nuevo texto")
        try expectEqual(DictationInsertion.text(transcript: "nuevo texto",
                                                existingText: "borrador",
                                                replacingSelection: true),
                        "nuevo texto")
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
