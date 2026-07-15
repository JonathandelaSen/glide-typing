import Foundation

enum DictationMode: Equatable, Sendable {
    case pushToTalk
    case handsFree
}

enum DictationStartSource: Equatable, Sendable {
    case pushToTalk
    case handsFreeHotKey
    case menu
    case button
    case voiceCommand(VoiceCommandContext)
}

enum DictationStopReason: Equatable, Sendable {
    case pushToTalkReleased
    case toggleShortcut
    case menu
    case button
    case trailingSilence
    case initialSilenceTimeout
}

enum DictationSessionOutcome: Equatable, Sendable {
    case delivered
    case empty
    case cancelled
    case unsafeVoicePrefix
    case failed(String)
}

enum DictationState: Equatable {
    case idle
    case preparing(DictationMode)
    case recording(DictationMode)
    case transcribing(DictationMode)
    case delivering(DictationMode)
    case failed(String)

    var statusText: String? {
        switch self {
        case .preparing: "Preparando micrófono…"
        case .recording(.pushToTalk): "Grabando · suelta el atajo para terminar"
        case .recording(.handsFree): "Grabando · termina con ⌥L, menú o 🎙"
        case .transcribing: "Transcribiendo localmente…"
        case .delivering: "Entregando dictado…"
        case .idle, .failed: nil
        }
    }
}

enum DictationInsertion {
    static func text(transcript: String, existingText: String,
                     replacingSelection: Bool = false) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        guard !replacingSelection else { return cleaned }
        guard let last = existingText.last, !last.isWhitespace else { return cleaned }
        return " " + cleaned
    }
}

private final class DeliveryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resolve() {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        continuation.resume()
    }
}

@MainActor
final class DictationController {
    typealias Deliver = (DictationSessionID, String, @escaping @Sendable () -> Void) -> Void

    private let transcriber: DictationTranscribing
    private let language: () -> String?
    private let willStart: (DictationSessionID) -> Void
    private let deliver: Deliver
    private let stateChanged: (DictationState) -> Void
    private var activeSessionID: DictationSessionID?
    private var startSource: DictationStartSource?

    private(set) var state: DictationState = .idle {
        didSet { stateChanged(state) }
    }

    init(transcriber: DictationTranscribing,
         language: @escaping () -> String?,
         willStart: @escaping (DictationSessionID) -> Void,
         deliver: @escaping Deliver,
         stateChanged: @escaping (DictationState) -> Void)
    {
        self.transcriber = transcriber
        self.language = language
        self.willStart = willStart
        self.deliver = deliver
        self.stateChanged = stateChanged
    }

    @discardableResult
    func prepare(sessionID: DictationSessionID,
                 mode: DictationMode,
                 source: DictationStartSource) -> Bool
    {
        guard state == .idle || isFailure else { return false }
        activeSessionID = sessionID
        startSource = source
        willStart(sessionID)
        state = .preparing(mode)
        return true
    }

    func recordingDidStart(sessionID: DictationSessionID) {
        guard activeSessionID == sessionID,
              case .preparing(let mode) = state else { return }
        state = .recording(mode)
    }

    func stop(sessionID: DictationSessionID,
              reason: DictationStopReason,
              samples: [Float]) async -> DictationSessionOutcome
    {
        guard activeSessionID == sessionID,
              case .recording(let mode) = state else { return .cancelled }
        if reason == .initialSilenceTimeout {
            clearSession()
            state = .idle
            return .empty
        }
        state = .transcribing(mode)

        do {
            let voiceContext: VoiceCommandContext?
            if case .voiceCommand(let context) = startSource {
                voiceContext = context
            } else {
                voiceContext = nil
            }
            let transcript = try await transcriber.transcribe(
                samples: samples,
                language: language(),
                wordTimestamps: voiceContext != nil
            )
            guard activeSessionID == sessionID else { return .cancelled }

            let output: String
            if let context = voiceContext {
                let commandEnd = TimeInterval(
                    context.estimatedCommandEndSample - context.sessionAudioStartSample
                ) / 16_000
                switch VoiceCommandPrefixTrimmer.trim(
                    transcript, wakeWord: context.wakeWordID,
                    estimatedCommandEnd: commandEnd
                ) {
                case .unsafe:
                    clearSession()
                    state = .idle
                    return .unsafeVoicePrefix
                case .success(let text):
                    output = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                output = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !output.isEmpty else {
                clearSession()
                state = .idle
                return .empty
            }
            state = .delivering(mode)
            await withCheckedContinuation { continuation in
                let once = DeliveryCompletion(continuation)
                deliver(sessionID, output) { once.resolve() }
            }
            guard activeSessionID == sessionID else { return .cancelled }
            clearSession()
            state = .idle
            return .delivered
        } catch {
            guard activeSessionID == sessionID else { return .cancelled }
            clearSession()
            state = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    func cancel(sessionID: DictationSessionID) {
        guard activeSessionID == sessionID else { return }
        clearSession()
        state = .idle
    }

    private func clearSession() {
        activeSessionID = nil
        startSource = nil
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }
}
