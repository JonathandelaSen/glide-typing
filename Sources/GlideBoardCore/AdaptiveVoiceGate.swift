import Foundation

/// Voice/non-voice decision relative to the measured noise floor of the
/// CURRENT input device. Absolute thresholds tuned on the MacBook microphone
/// (speech peaks ~0.02 rms) read Bluetooth headset speech (~0.006 rms) as
/// silence; this gate learns the device's noise level from quiet frames and
/// places the thresholds just above it, clamped so a loud environment can
/// never push them beyond the old fixed values.
struct AdaptiveVoiceGate: Sendable {
    private(set) var noiseRMS: Float

    init(initialNoiseRMS: Float = 0.002) {
        noiseRMS = initialNoiseRMS
    }

    /// Threshold to consider that voice STARTED (utterance onset).
    var startFloor: Float { min(0.012, max(0.0035, noiseRMS * 3)) }
    /// Hysteresis: once speaking, much quieter frames still count as voice.
    var continueFloor: Float { min(0.005, max(0.0018, noiseRMS * 1.8)) }

    /// `continuing` selects the hysteresis threshold (voice already active).
    /// Quiet frames feed the noise estimate; voiced frames never do, so
    /// continuous speech cannot poison the floor.
    mutating func isVoice(rms: Float, continuing: Bool) -> Bool {
        let voiced = rms >= (continuing ? continueFloor : startFloor)
        if rms < continueFloor {
            noiseRMS = min(0.02, noiseRMS * 0.98 + rms * 0.02)
        }
        return voiced
    }
}
