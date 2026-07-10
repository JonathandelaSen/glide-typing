import Foundation

protocol DictationEngine: AnyObject {
    func startRecording() async throws
    func stopRecordingAndTranscribe(language: String?) async throws -> String
    func cancelRecording()
}

enum DictationState: Equatable {
    case idle
    case preparing
    case recording
    case transcribing
    case failed(String)

    /// Persistent feedback for the only states where the user has to wait or
    /// perform an action. A short flash is too easy to miss while dictating.
    var statusText: String? {
        switch self {
        case .preparing: "Preparando micrófono…"
        case .recording: "Grabando · termina con el atajo o 🎙"
        case .transcribing: "Transcribiendo localmente…"
        case .idle, .failed: nil
        }
    }
}

enum DictationInsertion {
    static func text(transcript: String, existingText: String) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        guard let last = existingText.last, !last.isWhitespace else { return cleaned }
        return " " + cleaned
    }
}

@MainActor
final class DictationController {
    private let engine: DictationEngine
    private let language: () -> String?
    private let output: (String) -> Void
    private let stateChanged: (DictationState) -> Void
    private var releaseRequested = false

    private(set) var state: DictationState = .idle {
        didSet { stateChanged(state) }
    }

    init(engine: DictationEngine,
         language: @escaping () -> String?,
         output: @escaping (String) -> Void,
         stateChanged: @escaping (DictationState) -> Void)
    {
        self.engine = engine
        self.language = language
        self.output = output
        self.stateChanged = stateChanged
    }

    func press() async {
        guard state == .idle || isFailure else { return }
        releaseRequested = false
        state = .preparing
        do {
            try await engine.startRecording()
            state = .recording
            if releaseRequested {
                await release()
            }
        } catch {
            engine.cancelRecording()
            state = .failed(error.localizedDescription)
        }
    }

    func release() async {
        if state == .preparing {
            releaseRequested = true
            return
        }
        guard state == .recording else { return }
        state = .transcribing
        do {
            let transcript = try await engine.stopRecordingAndTranscribe(language: language())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                output(transcript)
            }
            state = .idle
        } catch {
            engine.cancelRecording()
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        releaseRequested = false
        engine.cancelRecording()
        state = .idle
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }
}
