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
    /// Optional decoder bias: Whisper leans towards transcribing the words of
    /// this phrase when the audio is ambiguous (the standard initial-prompt
    /// trick for custom vocabulary like a wake word). Nil keeps the decoder
    /// neutral. Experimental — only the lab sets it for now.
    var biasPrompt: String? = nil

    static func `default`(modelID: String) -> VoiceAttentionDescriptor {
        // Ring budget: wake window (32k) + wake inference latency (~16k) +
        // command window of 3 s (48k) + command window right context (32k) +
        // command inference latency (~16k) + safety margin. The plan's 96k
        // assumed 1 s classifier windows; WhisperKit's 2 s windows and real
        // inference latency do not fit in 6 s, and an overwritten ring kills
        // the voice reservation silently.
        VoiceAttentionDescriptor(
            backend: .whisperKit,
            modelID: modelID,
            language: "es",
            sampleRate: 16_000,
            ringCapacitySamples: 160_000,
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
        var options = DecodingOptions(
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
        if let prompt = descriptor.biasPrompt, !prompt.isEmpty,
           let tokenizer = whisperKit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
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

/// Lexical normalization shared by the command grammar and the prefix
/// trimmer. Matching itself lives in VoiceCommandGrammar.
enum VoiceAttentionIntentMatcher {
    static func normalize(_ token: String) -> String {
        let folded = token.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "es_ES"))
        let cleaned = folded.trimmingCharacters(
            in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        )
            .lowercased()
        // "graba" and "grava" are homophones in Spanish; the ASR picks either
        // spelling for the same acoustics. This is spelling tolerance for the
        // canonical command, not a synonym.
        return cleaned == "grava" ? "graba" : cleaned
    }
}
