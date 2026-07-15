import Foundation
import WhisperKit

enum WhisperKitDictationError: LocalizedError {
    case recordingTooShort
    case emptyResult
    case invalidWordTimings

    var errorDescription: String? {
        switch self {
        case .recordingTooShort: "La grabación es demasiado corta"
        case .emptyResult: "WhisperKit no devolvió una transcripción"
        case .invalidWordTimings: "WhisperKit devolvió timestamps de palabras no seguros"
        }
    }
}

enum DictationDecoding {
    static func options(language: String?, wordTimestamps: Bool = false) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: !wordTimestamps,
            wordTimestamps: wordTimestamps,
            concurrentWorkerCount: 1,
            chunkingStrategy: .vad
        )
    }
}

/// Whisper word timings routinely overlap the previous word by a few
/// milliseconds. That jitter is harmless for prefix trimming, so it is clamped
/// to a monotonic timeline; only a real inconsistency (a backwards jump larger
/// than the tolerance) fails the transcript.
enum WordTimingSanitizer {
    static let maximumOverlap: TimeInterval = 1.0

    static func sanitize(start: TimeInterval, end: TimeInterval,
                         previousEnd: TimeInterval)
        -> (start: TimeInterval, end: TimeInterval)?
    {
        guard end >= start, start >= previousEnd - maximumOverlap else { return nil }
        let clampedStart = max(start, previousEnd)
        return (clampedStart, max(end, clampedStart))
    }
}

enum WhisperTranscriptMapper {
    static func map(_ results: [TranscriptionResult],
                    wordTimestamps: Bool) throws -> DictationTranscript
    {
        guard wordTimestamps else {
            return DictationTranscript(
                text: results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                words: []
            )
        }

        var text = ""
        var words: [TranscribedWord] = []
        var previousEnd: TimeInterval = 0
        for word in results.flatMap(\.allWords) {
            guard let timing = WordTimingSanitizer.sanitize(
                start: TimeInterval(word.start),
                end: TimeInterval(word.end),
                previousEnd: previousEnd
            ) else {
                throw WhisperKitDictationError.invalidWordTimings
            }
            let lower = text.utf16.count
            text.append(word.word)
            let upper = text.utf16.count
            words.append(TranscribedWord(
                text: word.word,
                start: timing.start,
                end: timing.end,
                textRangeUTF16: lower..<upper
            ))
            previousEnd = timing.end
        }
        return DictationTranscript(text: text, words: words)
    }
}

/// Pure on-device transcriber. It receives an immutable 16 kHz snapshot and
/// never starts, stops or installs a microphone tap.
actor WhisperKitTranscriber: DictationTranscribing {
    private static let minimumSamples = WhisperKit.sampleRate / 4

    private let model: String
    private var pipeline: WhisperKit?

    init(model: String) {
        self.model = model
    }

    func transcribe(samples: [Float],
                    language: String?,
                    wordTimestamps: Bool,
                    biasPrompt: String?) async throws -> DictationTranscript
    {
        guard samples.count >= Self.minimumSamples else {
            throw WhisperKitDictationError.recordingTooShort
        }
        let whisperKit = try await loadPipeline()
        var options = DictationDecoding.options(
            language: language, wordTimestamps: wordTimestamps)
        if let biasPrompt, !biasPrompt.isEmpty, let tokenizer = whisperKit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + biasPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let transcript = try WhisperTranscriptMapper.map(
            results, wordTimestamps: wordTimestamps)
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WhisperKitDictationError.emptyResult
        }
        return transcript
    }

    private func loadPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )
        let loaded = try await WhisperKit(config)
        pipeline = loaded
        return loaded
    }
}
