import Foundation

enum HandsFreeSilenceEvent: Equatable {
    case `continue`
    case voiceStarted
    case initialSilenceTimeout
    case trailingSilence
}

struct HandsFreeSilenceDetector: Sendable {
    static let initialVoiceDeadlineSamples = 80_000
    static let trailingSilenceSamples = 32_000

    private var hasVoice = false
    private var initialSamples = 0
    private var trailingSamples = 0

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
            return trailingSamples >= Self.trailingSilenceSamples ? .trailingSilence : .continue
        }

        initialSamples += sampleCount
        return initialSamples >= Self.initialVoiceDeadlineSamples ? .initialSilenceTimeout : .continue
    }
}
