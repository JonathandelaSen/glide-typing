import Foundation

struct AudioFrame: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let rms: Float

    init(samples: [Float], sampleRate: Int = 16_000) {
        self.samples = samples
        self.sampleRate = sampleRate
        if samples.isEmpty {
            rms = 0
        } else {
            let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
            rms = sqrt(sum / Float(samples.count))
        }
    }
}
