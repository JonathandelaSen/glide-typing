import Foundation

struct TranscribedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let textRangeUTF16: Range<Int>
}

struct DictationTranscript: Equatable, Sendable {
    let text: String
    let words: [TranscribedWord]
}

protocol DictationTranscribing: AnyObject {
    func transcribe(samples: [Float],
                    language: String?,
                    wordTimestamps: Bool) async throws -> DictationTranscript
}
