import Foundation

enum HandsFreeSilenceEvent: Equatable {
    case `continue`
    case voiceStarted
    case initialSilenceTimeout
    case trailingSilence
}

struct HandsFreeSilenceDetector: Sendable {
    /// 8 s to start speaking after the session opens: the user may be
    /// gathering their thoughts after the green light.
    static let initialVoiceDeadlineSamples = 128_000
    /// Default trailing silence; the user-facing setting overrides it so
    /// thinking pauses don't cut the dictation.
    static let defaultTrailingSilenceSamples = 56_000
    let trailingSilenceSamples: Int

    private var hasVoice = false
    private var initialSamples = 0
    private var trailingSamples = 0

    /// Whether voice was heard at all — the caller's AdaptiveVoiceGate needs
    /// it to pick the hysteresis threshold.
    var voiceStarted: Bool { hasVoice }

    init(trailingSilenceSamples: Int = HandsFreeSilenceDetector.defaultTrailingSilenceSamples) {
        self.trailingSilenceSamples = max(8_000, trailingSilenceSamples)
    }

    mutating func ingest(sampleCount: Int, containsVoice: Bool) -> HandsFreeSilenceEvent {
        precondition(sampleCount >= 0)
        if containsVoice {
            let started = !hasVoice
            hasVoice = true
            trailingSamples = 0
            return started ? .voiceStarted : .continue
        }

        if hasVoice {
            trailingSamples += sampleCount
            return trailingSamples >= trailingSilenceSamples ? .trailingSilence : .continue
        }

        initialSamples += sampleCount
        return initialSamples >= Self.initialVoiceDeadlineSamples ? .initialSilenceTimeout : .continue
    }
}
