import Foundation

typealias DictationSessionID = UInt64

struct VoiceCommandContext: Equatable, Sendable {
    let audioReservationID: UInt64
    let wakeWordID: String
    let sessionAudioStartSample: Int64
    let commandDetectionWindowStartSample: Int64
    let commandDetectionWindowEndSample: Int64
    let estimatedCommandEndSample: Int64
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

    private final class State: @unchecked Sendable {
        var ring = AudioRingBuffer(capacity: 96_000)
        var routing: Routing = .attentive
        var sessionSamples: [Float] = []
        var nextReservationID: UInt64 = 0
        var finishedSessions = 0
    }

    private let state = State()

    init(executor: NumaAudioExecutor) {
        self.executor = executor
    }

    func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        executor.enqueue { [state] in
            state.ring.append(samples)
            switch state.routing {
            case .recording, .reserved:
                state.sessionSamples.append(contentsOf: samples)
            case .attentive, .discarding:
                break
            }
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
                           wakeWordID: String,
                           sessionAudioStartSample: Int64,
                           commandWindow: Range<Int64>,
                           estimatedCommandEndSample: Int64) async -> VoiceCommandContext?
    {
        await executor.perform { [state] in
            guard case .attentive = state.routing,
                  commandWindow.lowerBound <= commandWindow.upperBound,
                  commandWindow.upperBound <= state.ring.nextSample,
                  let samples = try? state.ring.samples(
                    in: sessionAudioStartSample..<state.ring.nextSample) else { return nil }
            state.nextReservationID &+= 1
            let reservationID = state.nextReservationID
            state.sessionSamples = samples
            state.routing = .reserved(sessionID, reservationID)
            return VoiceCommandContext(
                audioReservationID: reservationID,
                wakeWordID: wakeWordID,
                sessionAudioStartSample: sessionAudioStartSample,
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
            }
        }
    }

    func resetAudio() async {
        await executor.perform { [state] in
            state.sessionSamples.removeAll(keepingCapacity: false)
            state.ring.reset(origin: state.ring.nextSample)
            state.routing = .discarding
        }
    }

    func discardFrames() async {
        await executor.perform { [state] in
            state.sessionSamples.removeAll(keepingCapacity: true)
            state.routing = .discarding
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
