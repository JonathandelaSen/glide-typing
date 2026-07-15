import AVFoundation
import Foundation
import WhisperKit

enum MicrophoneCaptureError: LocalizedError {
    case permissionDenied
    case noInput
    case invalidInputFormat
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Numa no tiene permiso para usar el micrófono"
        case .noInput: "No hay ningún micrófono disponible"
        case .invalidInputFormat: "El formato del micrófono no es válido"
        case .converterUnavailable: "No se pudo convertir el audio a 16 kHz mono"
        }
    }
}

@MainActor
protocol MicrophoneCapturing: AnyObject {
    var isRunning: Bool { get }
    func start(generation: UInt64,
               frameHandler: @escaping @Sendable (AudioFrame) -> Void) async throws
    func stop(generation: UInt64)
}

/// Sole owner of the app's AVAudioEngine and input tap. Generation checks on
/// both sides of the permission await prevent a late start from resurrecting
/// capture after pause, lock, sleep or termination.
@MainActor
final class MicrophoneCaptureService: MicrophoneCapturing {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var currentGeneration: UInt64 = 0
    private var tapInstalled = false

    var isRunning: Bool { engine.isRunning && tapInstalled }

    func start(generation: UInt64,
               frameHandler: @escaping @Sendable (AudioFrame) -> Void) async throws
    {
        guard generation >= currentGeneration else { return }
        currentGeneration = generation
        if isRunning { return }

        guard !AudioProcessor.getAudioDevices().isEmpty else {
            throw MicrophoneCaptureError.noInput
        }
        guard await AudioProcessor.requestRecordPermission() else {
            throw MicrophoneCaptureError.permissionDenied
        }
        guard generation == currentGeneration else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneCaptureError.invalidInputFormat
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            buffer, _ in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 1)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil,
                  let channel = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel,
                                                    count: Int(output.frameLength)))
            guard !samples.isEmpty else { return }
            frameHandler(AudioFrame(samples: samples))
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapAndStop()
            throw error
        }
        if generation != currentGeneration {
            removeTapAndStop()
        }
    }

    func stop(generation: UInt64) {
        guard generation >= currentGeneration else { return }
        currentGeneration = generation
        removeTapAndStop()
    }

    private func removeTapAndStop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        converter = nil
    }
}
