import Foundation

/// Peak normalization for attention inference. Room microphones deliver
/// speech around -30 dBFS and the small Whisper models degrade badly there;
/// the lab measured the difference (docs/experiments/numa-wake-word-whisperkit.md).
/// The gain is capped so noise-only audio is not amplified into phantom
/// speech, and near-silence is left untouched.
enum AttentionAudioGain {
    static let maximumGain: Float = 12
    static let targetPeak: Float = 0.9

    static func gain(for samples: [Float]) -> Float {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.005 else { return 1 }
        return min(maximumGain, targetPeak / peak)
    }

    static func normalized(_ samples: [Float]) -> [Float] {
        let factor = gain(for: samples)
        guard factor != 1 else { return samples }
        return samples.map { $0 * factor }
    }
}
