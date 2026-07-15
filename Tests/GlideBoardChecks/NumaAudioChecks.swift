import Foundation
@testable import GlideBoardCore

@MainActor
func numaAudioChecks() async {
    let c = Checks.shared
    c.begin("Numa audio")

    await c.test("ring keeps exactly 96000 samples with absolute indices") {
        var ring = AudioRingBuffer(capacity: 96_000)
        ring.append(Array(repeating: 1, count: 95_999))
        try expectEqual(ring.availableRange, Int64(0)..<Int64(95_999))
        ring.append([2, 3])
        try expectEqual(ring.availableRange, Int64(1)..<Int64(96_001))
        try expectEqual(try ring.samples(in: 95_998..<96_001), [1, 2, 3])
        do {
            _ = try ring.samples(in: 0..<1)
            throw CheckFailure(message: "overwritten samples must fail", location: #fileID)
        } catch is AudioRingBufferError {}
    }

    await c.test("ring rejects future requests without clamping") {
        var ring = AudioRingBuffer(capacity: 4)
        ring.append([1, 2, 3])
        do {
            _ = try ring.samples(in: Int64(0)..<Int64(4))
            throw CheckFailure(message: "future range must fail", location: #fileID)
        } catch is AudioRingBufferError {}
    }

    await c.test("ring reset starts empty at the current absolute origin") {
        var ring = AudioRingBuffer(capacity: 4)
        ring.append([1, 2, 3])
        ring.reset()
        try expectEqual(ring.availableRange, Int64(3)..<Int64(3))
        try expectEqual(try ring.samples(in: 3..<3), [])
    }

    await c.test("hands-free VAD uses exact initial and trailing thresholds") {
        var initial = HandsFreeSilenceDetector()
        try expectEqual(initial.ingest(sampleCount: 79_999, containsVoice: false), .continue)
        try expectEqual(initial.ingest(sampleCount: 1, containsVoice: false), .initialSilenceTimeout)

        var trailing = HandsFreeSilenceDetector()
        try expectEqual(trailing.ingest(sampleCount: 10, containsVoice: true), .voiceStarted)
        try expectEqual(trailing.ingest(sampleCount: 31_999, containsVoice: false), .continue)
        try expectEqual(trailing.ingest(sampleCount: 1, containsVoice: false), .trailingSilence)
    }

    await c.test("voice resets trailing silence") {
        var detector = HandsFreeSilenceDetector()
        _ = detector.ingest(sampleCount: 10, containsVoice: true)
        _ = detector.ingest(sampleCount: 20_000, containsVoice: false)
        _ = detector.ingest(sampleCount: 1, containsVoice: true)
        try expectEqual(detector.ingest(sampleCount: 31_999, containsVoice: false), .continue)
        try expectEqual(detector.ingest(sampleCount: 1, containsVoice: false), .trailingSilence)
    }

    await c.test("pipeline and producer share one serial executor") {
        let executor = NumaAudioExecutor(label: "checks.shared")
        let pipeline = NumaAudioPipeline(executor: executor)
        try expectTrue(pipeline.executor === executor)
    }

    await c.test("sentinel frames cross a recording transition exactly once") {
        let executor = NumaAudioExecutor(label: "checks.sentinel")
        let pipeline = NumaAudioPipeline(executor: executor)
        pipeline.ingest(samples: [0, 1])
        try expectTrue(await pipeline.beginDictation(sessionID: 1, start: .now))
        pipeline.ingest(samples: [2, 3])
        pipeline.ingest(samples: [4, 5])
        let snapshot = try unwrap(await pipeline.finishDictation(sessionID: 1))
        try expectEqual(snapshot, [2, 3, 4, 5])
        try expectNil(await pipeline.finishDictation(sessionID: 1))
    }

    await c.test("100 cycles create one snapshot and leave no session buffer") {
        let pipeline = NumaAudioPipeline(executor: NumaAudioExecutor(label: "checks.cycles"))
        for sessionID in UInt64(1)...100 {
            try expectTrue(await pipeline.beginDictation(sessionID: sessionID, start: .now))
            pipeline.ingest(samples: [Float(sessionID)])
            try expectEqual(await pipeline.finishDictation(sessionID: sessionID),
                            [Float(sessionID)])
            try expectNil(await pipeline.finishDictation(sessionID: sessionID))
            await pipeline.armAttention()
        }
        let metrics = await pipeline.metrics()
        try expectEqual(metrics.finishedSessions, 100)
        try expectEqual(metrics.bufferedSessionSamples, 0)
    }

    await c.test("voice reservation is atomic and keeps later frames") {
        let pipeline = NumaAudioPipeline(executor: NumaAudioExecutor(label: "checks.reserve"))
        pipeline.ingest(samples: Array(0..<20).map(Float.init))
        let reserved = try unwrap(await pipeline.reserveVoiceAudio(
            sessionID: 7,
            wakeWordID: "numa",
            sessionAudioStartSample: 5,
            commandWindow: 8..<15,
            estimatedCommandEndSample: 14
        ))
        pipeline.ingest(samples: [20, 21])
        try expectTrue(await pipeline.beginDictation(
            sessionID: 7, start: .voice(reserved)))
        pipeline.ingest(samples: [22])
        let snapshot = try unwrap(await pipeline.finishDictation(sessionID: 7))
        try expectEqual(snapshot, Array(5...22).map(Float.init))
    }
}
