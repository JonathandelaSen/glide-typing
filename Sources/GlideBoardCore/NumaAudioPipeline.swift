import Foundation

typealias DictationSessionID = UInt64

/// Session audio always starts AFTER the command utterance closed, so the
/// dictation transcript never contains the command and needs no trimming.
struct VoiceCommandContext: Equatable, Sendable {
    let audioReservationID: UInt64
    /// Exact configured phrase that triggered the session ("Numa, graba").
    let commandPhrase: String
    let sessionAudioStartSample: Int64
    let commandDetectionWindowStartSample: Int64
    let commandDetectionWindowEndSample: Int64
    let estimatedCommandEndSample: Int64
}

/// State of the utterance the attention side is tracking while attentive:
/// still growing (the speaker hasn't paused yet) or closed by trailing
/// silence. Ranges are ring-absolute sample positions.
enum NumaAttentionUtterance: Equatable, Sendable {
    case growing(Range<Int64>)
    case closed(Range<Int64>)
}

enum NumaDictationBufferStart: Equatable, Sendable {
    case now
    case voice(VoiceCommandContext)
}

struct NumaAudioPipelineMetrics: Equatable, Sendable {
    let finishedSessions: Int
    let bufferedSessionSamples: Int
    let nextSample: Int64
}

final class NumaAudioPipeline: @unchecked Sendable {
    let executor: NumaAudioExecutor

    private enum Routing {
        case attentive
        case recording(DictationSessionID)
        case reserved(DictationSessionID, UInt64)
        case discarding
    }

    /// 0.5 s kept before the first voiced frame so the utterance doesn't lose
    /// its first syllable.
    static let utterancePreRollSamples: Int64 = 8_000
    /// 0.8 s of continuous silence closes the utterance.
    static let utteranceTrailingSilenceSamples = 12_800

    private final class State: @unchecked Sendable {
        var ring: AudioRingBuffer
        var routing: Routing = .attentive
        var sessionSamples: [Float] = []
        var nextReservationID: UInt64 = 0
        var finishedSessions = 0
        /// Utterance tracking, meaningful only while routing == .attentive.
        var utteranceStart: Int64?
        var utteranceSilentSamples = 0
        var closedUtterance: Range<Int64>?
        var utteranceGate = AdaptiveVoiceGate()

        init(ringCapacity: Int) {
            ring = AudioRingBuffer(capacity: ringCapacity)
        }

        func resetUtterance() {
            utteranceStart = nil
            utteranceSilentSamples = 0
            closedUtterance = nil
        }
    }

    private let state: State

    init(executor: NumaAudioExecutor, ringCapacity: Int = 96_000) {
        self.executor = executor
        state = State(ringCapacity: ringCapacity)
    }

    func ingest(samples: [Float], rms: Float? = nil) {
        guard !samples.isEmpty else { return }
        executor.enqueue { [state] in
            state.ring.append(samples)
            switch state.routing {
            case .recording, .reserved:
                state.sessionSamples.append(contentsOf: samples)
            case .attentive:
                let frameRMS = rms ?? AudioFrame(samples: samples).rms
                if state.utteranceGate.isVoice(rms: frameRMS,
                                               continuing: state.utteranceStart != nil) {
                    if state.utteranceStart == nil {
                        state.utteranceStart = max(
                            state.ring.availableRange.lowerBound,
                            state.ring.nextSample - Int64(samples.count)
                                - Self.utterancePreRollSamples
                        )
                    }
                    state.utteranceSilentSamples = 0
                } else if let start = state.utteranceStart {
                    state.utteranceSilentSamples += samples.count
                    if state.utteranceSilentSamples >= Self.utteranceTrailingSilenceSamples {
                        state.closedUtterance = start..<state.ring.nextSample
                        state.utteranceStart = nil
                        state.utteranceSilentSamples = 0
                    }
                }
            case .discarding:
                break
            }
        }
    }

    /// Current utterance while attentive. A closed utterance is consumed by
    /// the read: it is reported exactly once.
    func attentionUtterance() async -> NumaAttentionUtterance? {
        await executor.perform { [state] in
            guard case .attentive = state.routing else {
                state.resetUtterance()
                return nil
            }
            if let closed = state.closedUtterance {
                state.closedUtterance = nil
                return .closed(closed)
            }
            if let start = state.utteranceStart {
                return .growing(start..<state.ring.nextSample)
            }
            return nil
        }
    }

    /// Copies a ring range for attention inference, clamped to what is still
    /// available (an utterance can outgrow the ring; the command lives at its
    /// start, so the caller caps the length instead).
    func attentionSamples(in range: Range<Int64>) async -> [Float]? {
        await executor.perform { [state] in
            let available = state.ring.availableRange
            let lower = max(range.lowerBound, available.lowerBound)
            let upper = min(range.upperBound, available.upperBound)
            guard lower < upper else { return nil }
            return try? state.ring.samples(in: lower..<upper)
        }
    }

    func beginDictation(sessionID: DictationSessionID,
                        start: NumaDictationBufferStart) async -> Bool
    {
        await executor.perform { [state] in
            switch start {
            case .now:
                switch state.routing {
                case .attentive, .discarding:
                    break
                case .recording, .reserved:
                    return false
                }
                state.sessionSamples.removeAll(keepingCapacity: true)
                state.routing = .recording(sessionID)
                state.resetUtterance()
                return true
            case .voice(let context):
                guard context.audioReservationID > 0,
                      case .reserved(let activeSessionID, let reservationID) = state.routing,
                      activeSessionID == sessionID,
                      reservationID == context.audioReservationID else {
                    return false
                }
                state.routing = .recording(sessionID)
                return true
            }
        }
    }

    /// Copies the whole continuous prefix and switches routing before this FIFO
    /// operation returns. Frames arriving after it are appended to the reserved
    /// buffer even if MainActor is busy.
    func reserveVoiceAudio(sessionID: DictationSessionID,
                           commandPhrase: String,
                           sessionAudioStartSample: Int64,
                           commandWindow: Range<Int64>,
                           estimatedCommandEndSample: Int64) async -> VoiceCommandContext?
    {
        await executor.perform { [state] in
            // The session may start after the command utterance (clean flow),
            // so its start is clamped to "now" when the ring hasn't moved yet.
            let start = min(sessionAudioStartSample, state.ring.nextSample)
            guard case .attentive = state.routing,
                  commandWindow.lowerBound <= commandWindow.upperBound,
                  commandWindow.upperBound <= state.ring.nextSample,
                  let samples = try? state.ring.samples(
                    in: start..<state.ring.nextSample) else { return nil }
            state.nextReservationID &+= 1
            let reservationID = state.nextReservationID
            state.sessionSamples = samples
            state.routing = .reserved(sessionID, reservationID)
            state.resetUtterance()
            return VoiceCommandContext(
                audioReservationID: reservationID,
                commandPhrase: commandPhrase,
                sessionAudioStartSample: start,
                commandDetectionWindowStartSample: commandWindow.lowerBound,
                commandDetectionWindowEndSample: commandWindow.upperBound,
                estimatedCommandEndSample: estimatedCommandEndSample
            )
        }
    }

    func finishDictation(sessionID: DictationSessionID) async -> [Float]? {
        await executor.perform { [state] in
            guard case .recording(let activeSessionID) = state.routing,
                  activeSessionID == sessionID else { return nil }
            let snapshot = state.sessionSamples
            state.sessionSamples.removeAll(keepingCapacity: true)
            state.routing = .discarding
            state.finishedSessions += 1
            return snapshot
        }
    }

    func cancelDictation(sessionID: DictationSessionID) async {
        await executor.perform { [state] in
            switch state.routing {
            case .recording(let activeSessionID) where activeSessionID == sessionID,
                 .reserved(let activeSessionID, _) where activeSessionID == sessionID:
                state.sessionSamples.removeAll(keepingCapacity: true)
                state.routing = .discarding
            default:
                break
            }
        }
    }

    func armAttention() async {
        await executor.perform { [state] in
            switch state.routing {
            case .recording, .reserved:
                // A dictation session owns the buffers; arming attention now
                // would silently drop its audio.
                return
            case .attentive, .discarding:
                state.sessionSamples.removeAll(keepingCapacity: true)
                state.ring.reset(origin: state.ring.nextSample)
                state.routing = .attentive
                state.resetUtterance()
            }
        }
    }

    func resetAudio() async {
        await executor.perform { [state] in
            state.sessionSamples.removeAll(keepingCapacity: false)
            state.ring.reset(origin: state.ring.nextSample)
            state.routing = .discarding
            state.resetUtterance()
        }
    }

    func discardFrames() async {
        await executor.perform { [state] in
            state.sessionSamples.removeAll(keepingCapacity: true)
            state.routing = .discarding
            state.resetUtterance()
        }
    }

    func ringSnapshot(length: Int) async -> (samples: [Float], range: Range<Int64>)? {
        await executor.perform { [state] in
            guard length > 0, state.ring.availableRange.count >= length else { return nil }
            let end = state.ring.nextSample
            let start = end - Int64(length)
            guard let samples = try? state.ring.samples(in: start..<end) else { return nil }
            return (samples, start..<end)
        }
    }

    func metrics() async -> NumaAudioPipelineMetrics {
        await executor.perform { [state] in
            NumaAudioPipelineMetrics(
                finishedSessions: state.finishedSessions,
                bufferedSessionSamples: state.sessionSamples.count,
                nextSample: state.ring.nextSample
            )
        }
    }
}
