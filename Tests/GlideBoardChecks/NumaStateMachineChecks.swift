import Foundation
@testable import GlideBoardCore

@MainActor
private final class CaptureFake: MicrophoneCapturing {
    var isRunning = false
    var onConfigurationChange: (() -> Void)?
    var starts: [UInt64] = []
    var stops: [UInt64] = []
    var handler: (@Sendable (AudioFrame) -> Void)?
    var blockNextStart = false
    var startContinuation: CheckedContinuation<Void, Never>?

    func start(generation: UInt64,
               frameHandler: @escaping @Sendable (AudioFrame) -> Void) async throws {
        starts.append(generation)
        handler = frameHandler
        if blockNextStart {
            blockNextStart = false
            await withCheckedContinuation { startContinuation = $0 }
        }
        guard stops.last.map({ $0 <= generation }) ?? true else { return }
        isRunning = true
    }

    func stop(generation: UInt64) {
        stops.append(generation)
        isRunning = false
    }

    func emit(_ samples: [Float]) {
        handler?(AudioFrame(samples: samples))
    }
}

private final class AttentionRecognizerFake: VoiceAttentionRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    var transcripts: [AttentionTranscript] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var resets = 0
    private(set) var recognizeCalls = 0
    var prepareError: Error?

    func prepare() async throws {
        if let prepareError { throw prepareError }
    }

    func recognize(samples: [Float], sampleRate: Int,
                   wordTimestamps: Bool) async throws -> AttentionTranscript {
        let transcript = lock.withLock {
            active += 1
            recognizeCalls += 1
            maximumActive = max(maximumActive, active)
            // The last queued transcript keeps repeating: real inference on a
            // stable utterance returns the same text on every check.
            if transcripts.count > 1 { return transcripts.removeFirst() }
            return transcripts.first ?? AttentionTranscript(text: "", words: [])
        }
        await Task.yield()
        lock.withLock { active -= 1 }
        return transcript
    }

    func reset() {
        lock.lock(); resets += 1; lock.unlock()
    }
}

private final class NumaTranscriberFake: DictationTranscribing {
    var transcript = DictationTranscript(text: "hola", words: [])
    var calls = 0

    func transcribe(samples: [Float], language: String?,
                    wordTimestamps: Bool,
                    biasPrompt: String?) async throws -> DictationTranscript {
        calls += 1
        return transcript
    }
}

@MainActor
private func makeCoordinator(
    capture: CaptureFake,
    recognizer: AttentionRecognizerFake,
    transcriber: NumaTranscriberFake,
    captured: @escaping (DictationSessionID) -> Void = { _ in },
    delivered: @escaping (String) -> Void = { _ in },
    noticed: @escaping (String) -> Void = { _ in }
) -> NumaCoordinator {
    let controller = DictationController(
        transcriber: transcriber,
        language: { "es" },
        willStart: captured,
        deliver: { _, text, completion in delivered(text); completion() },
        stateChanged: { _ in }
    )
    return NumaCoordinator(
        capture: capture,
        pipeline: NumaAudioPipeline(executor: NumaAudioExecutor(label: "checks.coordinator")),
        recognizer: recognizer,
        descriptor: .default(modelID: "tiny"),
        controller: controller,
        stateChanged: { _ in },
        notice: { message, _ in noticed(message) },
        soundPlayer: SilentNumaSoundPlayer(),
        commands: { [VoiceCommandSetting(action: .record, phrase: "Numa, graba")] },
        trailingSilenceSeconds: { 2.0 }
    )
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor
func numaStateMachineChecks() async {
    let c = Checks.shared
    c.begin("Numa state machine")

    await c.test("launch starts attentive and pause is not persisted") {
        let capture = CaptureFake()
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(),
            transcriber: NumaTranscriberFake())
        await coordinator.startAtLaunch()
        try expectEqual(coordinator.state, .attentive)
        try expectEqual(capture.starts, [1])
        coordinator.pause()
        try expectEqual(coordinator.state, .pausedByUser)
        try expectEqual(capture.stops, [2])
    }

    await c.test("target is captured before an on-demand capture await") {
        let capture = CaptureFake()
        let recognizer = AttentionRecognizerFake()
        var targets = 0
        let coordinator = makeCoordinator(
            capture: capture, recognizer: recognizer,
            transcriber: NumaTranscriberFake(), captured: { _ in targets += 1 })
        await coordinator.startAtLaunch()
        coordinator.pause()
        capture.blockNextStart = true
        coordinator.pressPushToTalk()
        try expectTrue(await waitUntil { capture.startContinuation != nil })
        try expectEqual(targets, 1)
        try expectEqual(coordinator.state, .preparing(.pushToTalk))
        capture.startContinuation?.resume()
        try expectTrue(await waitUntil { coordinator.state == .recording(.pushToTalk) })
        coordinator.releasePushToTalk()
    }

    await c.test("a quick tap still records one push-to-talk session") {
        let capture = CaptureFake()
        let transcriber = NumaTranscriberFake()
        var delivered: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(), transcriber: transcriber,
            delivered: { delivered.append($0) })
        await coordinator.startAtLaunch()
        // The release fires before the press's async beginDictation has run.
        coordinator.pressPushToTalk()
        coordinator.releasePushToTalk()
        try expectTrue(await waitUntil { delivered == ["hola"] })
        try expectTrue(await waitUntil { coordinator.state == .attentive })
        try expectEqual(transcriber.calls, 1)
    }

    await c.test("push-to-talk records even when the attention model fails") {
        let capture = CaptureFake()
        let recognizer = AttentionRecognizerFake()
        recognizer.prepareError = NSError(domain: "attention", code: 1)
        let transcriber = NumaTranscriberFake()
        var delivered: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: recognizer, transcriber: transcriber,
            delivered: { delivered.append($0) })
        await coordinator.startAtLaunch()
        try expectEqual(coordinator.state, .unavailable("attentionModel"))
        coordinator.pressPushToTalk()
        try expectTrue(await waitUntil { coordinator.state == .recording(.pushToTalk) })
        capture.emit(Array(repeating: 0.2, count: 1_000))
        coordinator.releasePushToTalk()
        try expectTrue(await waitUntil { delivered == ["hola"] })
        try expectTrue(await waitUntil {
            coordinator.state == .unavailable("attentionModel") && !capture.isRunning
        })
    }

    await c.test("push-to-talk works while attention is still starting") {
        let capture = CaptureFake()
        let transcriber = NumaTranscriberFake()
        var delivered: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(), transcriber: transcriber,
            delivered: { delivered.append($0) })
        capture.blockNextStart = true
        let launch = Task { await coordinator.startAtLaunch() }
        try expectTrue(await waitUntil { capture.startContinuation != nil })
        try expectEqual(coordinator.state, .starting)
        coordinator.pressPushToTalk()
        try expectTrue(await waitUntil { coordinator.state == .recording(.pushToTalk) })
        coordinator.releasePushToTalk()
        try expectTrue(await waitUntil { delivered == ["hola"] })
        capture.startContinuation?.resume()
        await launch.value
        try expectTrue(await waitUntil { coordinator.state == .attentive })
    }

    await c.test("hands-free toggles and VAD stop share one snapshot") {
        let capture = CaptureFake()
        let transcriber = NumaTranscriberFake()
        var delivered: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(), transcriber: transcriber,
            delivered: { delivered.append($0) })
        await coordinator.startAtLaunch()
        coordinator.toggleHandsFree(source: .handsFreeHotKey)
        try expectTrue(await waitUntil { coordinator.state == .recording(.handsFree) })
        capture.emit(Array(repeating: 0.2, count: 100))
        capture.emit(Array(repeating: 0, count: 31_999))
        await Task.yield()
        try expectEqual(coordinator.state, .recording(.handsFree))
        capture.emit([0])
        try expectTrue(await waitUntil { coordinator.state == .attentive })
        try expectEqual(transcriber.calls, 1)
        try expectEqual(delivered, ["hola"])
    }

    await c.test("128000 initial silent samples cancel without Whisper") {
        let capture = CaptureFake()
        let transcriber = NumaTranscriberFake()
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(), transcriber: transcriber)
        await coordinator.startAtLaunch()
        coordinator.toggleHandsFree(source: .button)
        try expectTrue(await waitUntil { coordinator.state == .recording(.handsFree) })
        capture.emit(Array(repeating: 0, count: 127_999))
        await Task.yield()
        try expectEqual(coordinator.state, .recording(.handsFree))
        capture.emit([0])
        try expectTrue(await waitUntil { coordinator.state == .attentive })
        try expectEqual(transcriber.calls, 0)
    }

    await c.test("an audio device change restarts capture and re-arms") {
        let capture = CaptureFake()
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(),
            transcriber: NumaTranscriberFake())
        await coordinator.startAtLaunch()
        try expectEqual(capture.starts, [1])
        capture.onConfigurationChange?()
        try expectTrue(await waitUntil {
            capture.starts.count == 2 && coordinator.state == .attentive
        })
    }

    await c.test("a session without one voiced frame is discarded, not delivered") {
        let capture = CaptureFake()
        let transcriber = NumaTranscriberFake()
        var delivered: [String] = []
        var notices: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: AttentionRecognizerFake(), transcriber: transcriber,
            delivered: { delivered.append($0) }, noticed: { notices.append($0) })
        await coordinator.startAtLaunch()
        coordinator.toggleHandsFree(source: .button)
        try expectTrue(await waitUntil { coordinator.state == .recording(.handsFree) })
        // A mute device delivers frames of pure zeros.
        capture.emit(Array(repeating: 0, count: 16_000))
        coordinator.toggleHandsFree(source: .button)
        try expectTrue(await waitUntil { coordinator.state == .attentive })
        try expectEqual(transcriber.calls, 0)
        try expectTrue(delivered.isEmpty)
        try expectTrue(notices.contains("No he oído nada que dictar"))
    }

    await c.test("silent audio never reaches the attention model") {
        let capture = CaptureFake()
        let recognizer = AttentionRecognizerFake()
        let coordinator = makeCoordinator(
            capture: capture, recognizer: recognizer, transcriber: NumaTranscriberFake())
        await coordinator.startAtLaunch()
        capture.emit(Array(repeating: 0, count: 64_000))
        await Task.yield()
        try expectEqual(recognizer.recognizeCalls, 0)
        // Voice within the window re-enables the wake inference.
        capture.emit(Array(repeating: 0.1, count: 8_000))
        try expectTrue(await waitUntil { recognizer.recognizeCalls > 0 })
    }

    await c.test("exact command waits for the pause and dictates without trim") {
        let capture = CaptureFake()
        let recognizer = AttentionRecognizerFake()
        recognizer.transcripts = [AttentionTranscript(text: " ¡Numa, graba!", words: [])]
        let transcriber = NumaTranscriberFake()
        transcriber.transcript = DictationTranscript(text: "mañana tenemos", words: [])
        var delivered = ""
        let coordinator = makeCoordinator(
            capture: capture, recognizer: recognizer, transcriber: transcriber,
            delivered: { delivered = $0 })
        await coordinator.startAtLaunch()
        // The exact command while still speaking does not start a session…
        capture.emit(Array(repeating: 0.1, count: 24_000))
        try expectTrue(await waitUntil { recognizer.recognizeCalls > 0 })
        try expectEqual(coordinator.state, .attentive)
        // …the pause closes the utterance and the clean session starts.
        capture.emit(Array(repeating: 0, count: 16_000))
        try expectTrue(await waitUntil { coordinator.state == .recording(.handsFree) })
        capture.emit(Array(repeating: 0.2, count: 100))
        capture.emit(Array(repeating: 0, count: 32_000))
        try expectTrue(await waitUntil { coordinator.state == .attentive })
        try expectEqual(delivered, "mañana tenemos")
        try expectEqual(recognizer.maximumActive, 1)
    }

    await c.test("same-breath dictation is rejected and teaches the signal") {
        let capture = CaptureFake()
        let recognizer = AttentionRecognizerFake()
        recognizer.transcripts = [
            AttentionTranscript(text: " Numa, graba, mañana tenemos", words: [])
        ]
        let transcriber = NumaTranscriberFake()
        var notices: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: recognizer, transcriber: transcriber,
            noticed: { notices.append($0) })
        await coordinator.startAtLaunch()
        capture.emit(Array(repeating: 0.1, count: 24_000))
        capture.emit(Array(repeating: 0, count: 16_000))
        try expectTrue(await waitUntil {
            notices.contains("Di «Numa, graba», espera la señal y dicta")
        })
        try expectEqual(coordinator.state, .attentive)
        try expectEqual(transcriber.calls, 0)
    }

    await c.test("closed speech without the command notifies and stays attentive") {
        let capture = CaptureFake()
        let recognizer = AttentionRecognizerFake()
        recognizer.transcripts = [
            AttentionTranscript(
                text: " Numa, apaga",
                words: [
                    AttentionWord(text: " Numa,", start: 0.5, end: 0.8,
                                  textRangeUTF16: 0..<6),
                    AttentionWord(text: " apaga", start: 0.85, end: 1.1,
                                  textRangeUTF16: 6..<12),
                ]
            ),
            AttentionTranscript(
                text: " Numa, apaga",
                words: [
                    AttentionWord(text: " Numa,", start: 0.5, end: 0.8,
                                  textRangeUTF16: 0..<6),
                    AttentionWord(text: " apaga", start: 0.85, end: 1.1,
                                  textRangeUTF16: 6..<12),
                ]
            )
        ]
        var notices: [String] = []
        let coordinator = makeCoordinator(
            capture: capture, recognizer: recognizer, transcriber: NumaTranscriberFake(),
            noticed: { notices.append($0) })
        await coordinator.startAtLaunch()
        capture.emit(Array(repeating: 0.1, count: 24_000))
        capture.emit(Array(repeating: 0, count: 16_000))
        try expectTrue(await waitUntil { notices.contains("No te he entendido") })
        try expectEqual(coordinator.state, .attentive)
    }
}
