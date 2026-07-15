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
    /// `biasPrompt` leans the decoder towards expected vocabulary (the voice
    /// command phrase at the start of a voice session's audio); nil keeps it
    /// neutral for plain dictation.
    func transcribe(samples: [Float],
                    language: String?,
                    wordTimestamps: Bool,
                    biasPrompt: String?) async throws -> DictationTranscript
}
