import Foundation
import WhisperKit

enum VoiceAttentionBackend: String, Equatable, Sendable {
    case whisperKit
}

struct VoiceAttentionDescriptor: Equatable, Sendable {
    let backend: VoiceAttentionBackend
    let modelID: String
    let language: String?
    let sampleRate: Int
    let ringCapacitySamples: Int
    let windowSamples: Int
    let hopSamples: Int
    let voiceRMSFloor: Float

    static func `default`(modelID: String) -> VoiceAttentionDescriptor {
        VoiceAttentionDescriptor(
            backend: .whisperKit,
            modelID: modelID,
            language: "es",
            sampleRate: 16_000,
            ringCapacitySamples: 96_000,
            windowSamples: 32_000,
            hopSamples: 8_000,
            voiceRMSFloor: 0.012
        )
    }
}

enum VoiceAttentionModelID {
    /// This list is derived from the `ModelVariant` API in the pinned
    /// WhisperKit dependency, rather than duplicating guessed model strings.
    static let supported: Set<String> = Set(
        ModelVariant.allCases
            .filter(\.isMultilingual)
            .map(\.description)
    )

    static func isSupported(_ modelID: String) -> Bool {
        supported.contains(modelID)
    }
}

struct AttentionWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let textRangeUTF16: Range<Int>
}

struct AttentionTranscript: Equatable, Sendable {
    let text: String
    let words: [AttentionWord]
}

protocol VoiceAttentionRecognizing: AnyObject {
    func prepare() async throws
    func recognize(samples: [Float],
                   sampleRate: Int,
                   wordTimestamps: Bool) async throws -> AttentionTranscript
    func reset()
}

enum VoiceAttentionRecognizerError: LocalizedError {
    case unsupportedModel(String)
    case invalidSampleRate(Int)
    case staleInference

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let model):
            "Modelo de attention no compatible: \(model)"
        case .invalidSampleRate(let rate):
            "Numa esperaba audio a 16000 Hz, no \(rate) Hz"
        case .staleInference:
            "La inferencia de attention ya no pertenece a la sesión vigente"
        }
    }
}

private final class AttentionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

/// The actor is the serialization boundary: model loading and every inference
/// are mutually exclusive. It consumes sample arrays only and never owns an
/// AudioProcessor capable of opening the microphone.
actor WhisperKitVoiceAttentionRecognizer: VoiceAttentionRecognizing {
    private let descriptor: VoiceAttentionDescriptor
    private nonisolated let generation = AttentionGeneration()
    private var pipeline: WhisperKit?

    init(descriptor: VoiceAttentionDescriptor) {
        self.descriptor = descriptor
    }

    func prepare() async throws {
        guard VoiceAttentionModelID.isSupported(descriptor.modelID) else {
            throw VoiceAttentionRecognizerError.unsupportedModel(descriptor.modelID)
        }
        _ = try await loadPipeline()
    }

    func recognize(samples: [Float],
                   sampleRate: Int,
                   wordTimestamps: Bool) async throws -> AttentionTranscript
    {
        guard sampleRate == descriptor.sampleRate else {
            throw VoiceAttentionRecognizerError.invalidSampleRate(sampleRate)
        }
        let inferenceGeneration = generation.snapshot()
        let whisperKit = try await loadPipeline()
        let options = DecodingOptions(
            task: .transcribe,
            language: descriptor.language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: descriptor.language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: !wordTimestamps,
            wordTimestamps: wordTimestamps,
            concurrentWorkerCount: 1
        )
        let results = try await whisperKit.transcribe(audioArray: samples,
                                                      decodeOptions: options)
        guard inferenceGeneration == generation.snapshot() else {
            throw VoiceAttentionRecognizerError.staleInference
        }
        return Self.map(results: results, wordTimestamps: wordTimestamps)
    }

    nonisolated func reset() {
        generation.increment()
    }

    private func loadPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        guard VoiceAttentionModelID.isSupported(descriptor.modelID) else {
            throw VoiceAttentionRecognizerError.unsupportedModel(descriptor.modelID)
        }
        let config = WhisperKitConfig(
            model: descriptor.modelID,
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

    private static func map(results: [TranscriptionResult],
                            wordTimestamps: Bool) -> AttentionTranscript
    {
        guard wordTimestamps else {
            return AttentionTranscript(
                text: results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                words: []
            )
        }

        var text = ""
        var words: [AttentionWord] = []
        for timing in results.flatMap(\.allWords) {
            let lower = text.utf16.count
            text.append(timing.word)
            let upper = text.utf16.count
            words.append(AttentionWord(
                text: timing.word,
                start: TimeInterval(timing.start),
                end: TimeInterval(timing.end),
                textRangeUTF16: lower..<upper
            ))
        }
        return AttentionTranscript(text: text, words: words)
    }
}

/// Stand-in used when the configured attention model can't be created, so the
/// coordinator parks attention in .unavailable while push-to-talk and
/// hands-free dictation keep working.
final class UnavailableVoiceAttentionRecognizer: VoiceAttentionRecognizing {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func prepare() async throws { throw error }

    func recognize(samples: [Float], sampleRate: Int,
                   wordTimestamps: Bool) async throws -> AttentionTranscript {
        throw error
    }

    func reset() {}
}

enum VoiceAttentionRecognizerFactory {
    static func make(descriptor: VoiceAttentionDescriptor) throws -> VoiceAttentionRecognizing {
        guard descriptor.backend == .whisperKit,
              VoiceAttentionModelID.isSupported(descriptor.modelID) else {
            throw VoiceAttentionRecognizerError.unsupportedModel(descriptor.modelID)
        }
        return WhisperKitVoiceAttentionRecognizer(descriptor: descriptor)
    }
}

enum VoiceAttentionIntentMatcher {
    static func containsWakeWord(_ text: String) -> Bool {
        lexicalTokens(text).contains("numa")
    }

    static func containsCommand(_ text: String) -> Bool {
        let tokens = lexicalTokens(text)
        let commandStart = tokens.first == "numa" ? 1 : 0
        guard tokens.count >= commandStart + 2 else { return false }
        return tokens[commandStart] == "graba" && tokens[commandStart + 1] == "audio"
    }

    static func commandEndTime(_ transcript: AttentionTranscript) -> TimeInterval? {
        let tokens = transcript.words.map { normalize($0.text) }
        let commandStart = tokens.first == "numa" ? 1 : 0
        guard tokens.count >= commandStart + 2,
              tokens[commandStart] == "graba",
              tokens[commandStart + 1] == "audio" else { return nil }
        return transcript.words[commandStart + 1].end
    }

    private static func lexicalTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    static func normalize(_ token: String) -> String {
        let folded = token.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "es_ES"))
        return folded.trimmingCharacters(
            in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        )
            .lowercased()
    }
}
