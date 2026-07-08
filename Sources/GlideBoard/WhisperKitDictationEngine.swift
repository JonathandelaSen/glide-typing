import Foundation
import WhisperKit

enum WhisperKitDictationError: LocalizedError {
    case microphonePermissionDenied
    case recordingTooShort
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "GlideBoard no tiene permiso para usar el micrófono"
        case .recordingTooShort:
            return "Mantén pulsado el atajo un poco más"
        case .emptyResult:
            return "WhisperKit no devolvió una transcripción"
        }
    }
}

/// Local, on-device speech-to-text. Audio capture starts without waiting for
/// the model; the selected Core ML model is downloaded and loaded only after
/// the first recording is complete, so initial setup never loses spoken audio.
final class WhisperKitDictationEngine: DictationEngine {
    private static let minimumSamples = WhisperKit.sampleRate / 4

    private let model: String
    private let audioProcessor = AudioProcessor()
    private var pipeline: WhisperKit?

    init(model: String) {
        self.model = model
    }

    func startRecording() async throws {
        let inputDevices = AudioProcessor.getAudioDevices()
        try requireMicrophoneInput(deviceCount: inputDevices.count)
        guard await AudioProcessor.requestRecordPermission() else {
            throw WhisperKitDictationError.microphonePermissionDenied
        }
        try audioProcessor.startRecordingLive(inputDeviceID: inputDevices[0].id, callback: nil)
    }

    func stopRecordingAndTranscribe(language: String) async throws -> String {
        audioProcessor.stopRecording()
        let samples = Array(audioProcessor.audioSamples)
        guard samples.count >= Self.minimumSamples else {
            throw WhisperKitDictationError.recordingTooShort
        }

        let whisperKit = try await loadPipeline()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisperKit.transcribe(audioArray: samples,
                                                      decodeOptions: options)
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WhisperKitDictationError.emptyResult }
        return text
    }

    func cancelRecording() {
        audioProcessor.stopRecording()
    }

    private func loadPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }

        let config = WhisperKitConfig(
            model: model,
            audioProcessor: audioProcessor,
            verbose: false,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )
        let pipeline = try await WhisperKit(config)
        self.pipeline = pipeline
        return pipeline
    }
}
