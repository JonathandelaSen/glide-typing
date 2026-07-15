import Foundation

enum NumaState: Equatable {
    case stopped
    case starting
    case attentive
    case preparing(DictationMode)
    case recording(DictationMode)
    case transcribing(DictationMode)
    case delivering(DictationMode)
    case pausedByUser
    case suspended
    case unavailable(String)
}

@MainActor
final class NumaCoordinator {
    private let capture: MicrophoneCapturing
    private let pipeline: NumaAudioPipeline
    private let recognizer: VoiceAttentionRecognizing
    private let descriptor: VoiceAttentionDescriptor
    private let controller: DictationController
    private let stateChanged: (NumaState) -> Void
    private let notice: (String, TimeInterval) -> Void
    private let soundPlayer: NumaSoundPlaying
    private let soundTheme: () -> NumaSoundTheme
    private let rmsChanged: (Float) -> Void
    private let commandRecognized: (String) -> Void
    private let commands: () -> [VoiceCommandSetting]
    private let trailingSilenceSeconds: () -> Double

    private var captureGeneration: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var nextSessionID: DictationSessionID = 0
    private var activeSessionID: DictationSessionID?
    private var activeMode: DictationMode?
    private var pendingStop: DictationStopReason?
    private var stopInProgress = false
    private var silenceDetector = HandsFreeSilenceDetector()
    private var attentionPrepared = false
    private var attentionInferenceInFlight = false
    private var attentionInferencePending = false
    private var samplesSinceAttentionWindow = 0
    /// Utterance already checked up to the length cap without matching a
    /// command; skip further inference on it until it closes.
    private var abandonedUtteranceStart: Int64?
    /// A command is at the start of the utterance, so 0.7 s of audio is the
    /// minimum worth transcribing and 8 s the cap for repeated checks.
    private static let minimumDetectionSamples: Int64 = 11_200
    private static let maximumDetectionSamples: Int64 = 128_000
    private var userAttentionEnabled = true
    private var suspended = false
    /// Tracks the physical key so a tap whose release arrives before
    /// `beginDictation` has run still stops the session it started.
    private var pushToTalkHeld = false
    /// Rate limit for the "heard speech, no match" diagnostics, so live tests
    /// can tell "not hearing you" apart from "not understanding you" without
    /// flooding the log.
    private var lastUnmatchedSpeechLog = Date.distantPast
    /// Whisper hallucinates a constant phrase on silent windows; running the
    /// wake inference without voice-level audio burns CPU and pollutes the
    /// diagnostics. Starts as "long silence" so launch stays idle until the
    /// first voiced frame.
    private var samplesSinceVoice = Int.max / 2
    private var activeSoundTheme: NumaSoundTheme = .crystal
    private var resetAudioTask: Task<Void, Never>?

    private(set) var state: NumaState = .stopped {
        didSet { stateChanged(state) }
    }

    init(capture: MicrophoneCapturing,
         pipeline: NumaAudioPipeline,
         recognizer: VoiceAttentionRecognizing,
         descriptor: VoiceAttentionDescriptor,
         controller: DictationController,
         stateChanged: @escaping (NumaState) -> Void,
         notice: @escaping (String, TimeInterval) -> Void,
         soundPlayer: NumaSoundPlaying,
         soundTheme: @escaping () -> NumaSoundTheme = { .crystal },
         rmsChanged: @escaping (Float) -> Void = { _ in },
         commandRecognized: @escaping (String) -> Void = { _ in },
         commands: @escaping () -> [VoiceCommandSetting] = { VoiceCommandSetting.defaults },
         trailingSilenceSeconds: @escaping () -> Double = { 3.5 })
    {
        self.capture = capture
        self.pipeline = pipeline
        self.recognizer = recognizer
        self.descriptor = descriptor
        self.controller = controller
        self.stateChanged = stateChanged
        self.notice = notice
        self.soundPlayer = soundPlayer
        self.soundTheme = soundTheme
        self.rmsChanged = rmsChanged
        self.commandRecognized = commandRecognized
        self.commands = commands
        self.trailingSilenceSeconds = trailingSilenceSeconds
    }

    func startAtLaunch() async {
        guard state == .stopped else { return }
        state = .starting
        if let resetAudioTask {
            await resetAudioTask.value
            self.resetAudioTask = nil
        }
        captureGeneration &+= 1
        let generation = captureGeneration
        do {
            try await capture.start(generation: generation) { [weak self] frame in
                guard let self else { return }
                self.pipeline.ingest(samples: frame.samples, rms: frame.rms)
                Task { @MainActor [weak self] in self?.received(frame) }
            }
            guard generation == captureGeneration else { return }
            // A manual session may have started while capture was coming up;
            // never reclaim its audio or overwrite its state.
            if activeSessionID == nil {
                await pipeline.armAttention()
                if activeSessionID == nil { state = .attentive }
            }
        } catch {
            guard generation == captureGeneration else { return }
            state = .unavailable("microphone")
            DictationLog.write("numa: micrófono no disponible — \(error.localizedDescription)")
            notice(error.localizedDescription, 2.4)
            return
        }

        do {
            try await recognizer.prepare()
            attentionPrepared = true
            DictationLog.write("numa: atención lista (escuchando el wake word)")
        } catch {
            attentionPrepared = false
            if state == .attentive {
                captureGeneration &+= 1
                capture.stop(generation: captureGeneration)
                state = .unavailable("attentionModel")
            }
            DictationLog.write("numa: modelo de atención no disponible — \(error.localizedDescription)")
            notice(error.localizedDescription, 2.4)
        }
    }

    func pressPushToTalk() {
        pushToTalkHeld = true
        Task { await beginDictation(mode: .pushToTalk, source: .pushToTalk) }
    }

    func releasePushToTalk() {
        pushToTalkHeld = false
        requestStop(.pushToTalkReleased, expectedMode: .pushToTalk)
    }

    func toggleHandsFree(source: DictationStartSource) {
        if activeMode == .handsFree {
            let reason: DictationStopReason = switch source {
            case .menu: .menu
            case .button: .button
            default: .toggleShortcut
            }
            requestStop(reason, expectedMode: .handsFree)
        } else {
            Task { await beginDictation(mode: .handsFree, source: source) }
        }
    }

    func pause() {
        userAttentionEnabled = false
        streamGeneration &+= 1
        recognizer.reset()
        if let sessionID = activeSessionID {
            controller.cancel(sessionID: sessionID)
            Task { await pipeline.cancelDictation(sessionID: sessionID) }
        }
        resetAudioTask = Task { await pipeline.resetAudio() }
        clearSession()
        captureGeneration &+= 1
        capture.stop(generation: captureGeneration)
        state = .pausedByUser
    }

    func resume() {
        guard state == .pausedByUser else { return }
        userAttentionEnabled = true
        state = .stopped
        Task { await startAtLaunch() }
    }

    func setSuspended(_ shouldSuspend: Bool) {
        guard suspended != shouldSuspend else { return }
        suspended = shouldSuspend
        if shouldSuspend {
            streamGeneration &+= 1
            recognizer.reset()
            if let sessionID = activeSessionID {
                controller.cancel(sessionID: sessionID)
                Task { await pipeline.cancelDictation(sessionID: sessionID) }
            }
            clearSession()
            resetAudioTask = Task { await pipeline.resetAudio() }
            captureGeneration &+= 1
            capture.stop(generation: captureGeneration)
            state = .suspended
        } else if userAttentionEnabled {
            state = .stopped
            Task { await startAtLaunch() }
        } else {
            state = .pausedByUser
        }
    }

    func terminate() {
        streamGeneration &+= 1
        recognizer.reset()
        captureGeneration &+= 1
        capture.stop(generation: captureGeneration)
        resetAudioTask = Task { await pipeline.resetAudio() }
        state = .stopped
    }

    private func beginDictation(mode: DictationMode,
                                source: DictationStartSource) async
    {
        // Manual dictation must not depend on the attention pipeline's health:
        // only an in-flight session blocks it.
        guard activeSessionID == nil else { return }
        switch state {
        case .preparing, .recording, .transcribing, .delivering: return
        default: break
        }
        nextSessionID &+= 1
        let sessionID = nextSessionID
        guard controller.prepare(sessionID: sessionID, mode: mode, source: source) else { return }
        activeSessionID = sessionID
        activeMode = mode
        pendingStop = nil
        silenceDetector = HandsFreeSilenceDetector(
            trailingSilenceSamples: Int(trailingSilenceSeconds()
                * Double(descriptor.sampleRate)))
        activeSoundTheme = soundTheme()
        if case .voiceCommand = source {} else {
            soundPlayer.playActivation(theme: activeSoundTheme)
        }
        streamGeneration &+= 1
        recognizer.reset()
        state = .preparing(mode)

        if let resetAudioTask {
            await resetAudioTask.value
            self.resetAudioTask = nil
        }

        let start: NumaDictationBufferStart
        if case .voiceCommand(let context) = source {
            start = .voice(context)
        } else {
            start = .now
        }
        let began = await pipeline.beginDictation(sessionID: sessionID, start: start)
        guard activeSessionID == sessionID else { return }
        guard began else {
            DictationLog.write("numa: el pipeline rechazó la sesión \(sessionID)")
            controller.cancel(sessionID: sessionID)
            clearSession()
            state = .unavailable("audioPipeline")
            return
        }

        if !capture.isRunning {
            captureGeneration &+= 1
            let generation = captureGeneration
            do {
                try await capture.start(generation: generation) { [weak self] frame in
                    guard let self else { return }
                    self.pipeline.ingest(samples: frame.samples, rms: frame.rms)
                    Task { @MainActor [weak self] in self?.received(frame) }
                }
            } catch {
                DictationLog.write("numa: micrófono falló al iniciar la sesión \(sessionID) — \(error.localizedDescription)")
                await pipeline.cancelDictation(sessionID: sessionID)
                controller.cancel(sessionID: sessionID)
                clearSession()
                state = .unavailable("microphone")
                notice(error.localizedDescription, 2.4)
                return
            }
        }
        guard activeSessionID == sessionID else { return }
        controller.recordingDidStart(sessionID: sessionID)
        state = .recording(mode)
        if let pendingStop {
            self.pendingStop = nil
            await stop(sessionID: sessionID, reason: pendingStop)
        } else if mode == .pushToTalk, !pushToTalkHeld {
            // The key was tapped: its release fired before recording began.
            await stop(sessionID: sessionID, reason: .pushToTalkReleased)
        }
    }

    private func requestStop(_ reason: DictationStopReason,
                             expectedMode: DictationMode)
    {
        guard activeMode == expectedMode, let sessionID = activeSessionID else { return }
        if case .preparing = state {
            if pendingStop == nil { pendingStop = reason }
            return
        }
        guard case .recording = state else { return }
        Task { await stop(sessionID: sessionID, reason: reason) }
    }

    private func stop(sessionID: DictationSessionID,
                      reason: DictationStopReason) async
    {
        guard !stopInProgress, activeSessionID == sessionID,
              let mode = activeMode else { return }
        stopInProgress = true
        defer { stopInProgress = false }
        if reason == .initialSilenceTimeout {
            let deadline = HandsFreeSilenceDetector.initialVoiceDeadlineSamples
                / descriptor.sampleRate
            DictationLog.write("numa: sesión \(sessionID) cancelada — \(deadline) s sin voz que dictar")
            await pipeline.cancelDictation(sessionID: sessionID)
            await soundPlayer.playFinish(theme: activeSoundTheme)
            controller.cancel(sessionID: sessionID)
            clearSession()
            notice("No he oído nada que dictar", 1.6)
            await rearmAfterSession()
            return
        }
        guard let samples = await pipeline.finishDictation(sessionID: sessionID) else {
            // The pipeline lost the session (a pause/suspend raced us). Never
            // leave the coordinator parked in .recording with a dead session.
            if activeSessionID == sessionID {
                DictationLog.write("numa: el pipeline perdió la sesión \(sessionID); se cancela")
                controller.cancel(sessionID: sessionID)
                clearSession()
                await rearmAfterSession()
            }
            return
        }
        await soundPlayer.playFinish(theme: activeSoundTheme)
        state = .transcribing(mode)
        let outcome = await controller.stop(sessionID: sessionID, reason: reason, samples: samples)
        DictationLog.write("numa: sesión \(sessionID) terminada (\(mode), \(reason), \(outcome), \(samples.count) muestras)")
        guard activeSessionID == sessionID else { return }
        clearSession()
        await rearmAfterSession()
    }

    private func rearmAfterSession() async {
        streamGeneration &+= 1
        recognizer.reset()
        if suspended {
            captureGeneration &+= 1
            capture.stop(generation: captureGeneration)
            state = .suspended
        } else if !userAttentionEnabled {
            captureGeneration &+= 1
            capture.stop(generation: captureGeneration)
            state = .pausedByUser
        } else if attentionPrepared {
            await pipeline.armAttention()
            state = .attentive
        } else {
            // Attention never came up (model failed or launch was interrupted
            // by a manual session). Retry the full bring-up; if it fails again
            // it parks in .unavailable with the microphone closed, and manual
            // dictation keeps working from there.
            captureGeneration &+= 1
            capture.stop(generation: captureGeneration)
            state = .stopped
            Task { await startAtLaunch() }
        }
    }

    private func received(_ frame: AudioFrame) {
        rmsChanged(frame.rms)
        if frame.rms >= descriptor.voiceRMSFloor {
            samplesSinceVoice = 0
        } else if samplesSinceVoice < Int.max / 2 {
            samplesSinceVoice += frame.samples.count
        }
        if activeMode == .handsFree, case .recording = state {
            let event = silenceDetector.ingest(
                sampleCount: frame.samples.count,
                containsVoice: frame.rms >= descriptor.voiceRMSFloor
            )
            switch event {
            case .initialSilenceTimeout:
                requestStop(.initialSilenceTimeout, expectedMode: .handsFree)
            case .trailingSilence:
                requestStop(.trailingSilence, expectedMode: .handsFree)
            case .continue, .voiceStarted:
                break
            }
            return
        }

        guard attentionPrepared, state == .attentive else { return }
        samplesSinceAttentionWindow += frame.samples.count
        guard samplesSinceAttentionWindow >= descriptor.hopSamples else { return }
        samplesSinceAttentionWindow %= descriptor.hopSamples
        // Only work when voice was heard recently: the utterance keeps
        // growing while the user speaks, and once it closes (0.8 s of
        // silence) it is consumed well before this gate cuts off the hops.
        if samplesSinceVoice >= descriptor.windowSamples { return }
        scheduleAttentionInference()
    }

    private func scheduleAttentionInference() {
        guard !attentionInferenceInFlight else {
            attentionInferencePending = true
            return
        }
        attentionInferenceInFlight = true
        let generation = streamGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.checkUtterance(generation: generation)
            self.attentionInferenceFinished()
        }
    }

    private func checkUtterance(generation: UInt64) async {
        guard let utterance = await pipeline.attentionUtterance() else { return }
        switch utterance {
        case .growing(let range):
            let length = range.upperBound - range.lowerBound
            guard length >= Self.minimumDetectionSamples,
                  abandonedUtteranceStart != range.lowerBound else { return }
            if length > Self.maximumDetectionSamples {
                // The command lives at the start; if it hasn't matched within
                // the cap this is ordinary conversation. Stop re-checking it.
                abandonedUtteranceStart = range.lowerBound
                return
            }
            await detectCommand(in: range, utteranceClosed: false, generation: generation)
        case .closed(let range):
            let wasAbandoned = abandonedUtteranceStart == range.lowerBound
            abandonedUtteranceStart = nil
            guard !wasAbandoned,
                  range.upperBound - range.lowerBound >= Self.minimumDetectionSamples
            else { return }
            await detectCommand(in: range, utteranceClosed: true, generation: generation)
        }
    }

    private func detectCommand(in range: Range<Int64>, utteranceClosed: Bool,
                               generation: UInt64) async
    {
        let cappedUpper = min(range.upperBound,
                              range.lowerBound + Self.maximumDetectionSamples)
        guard let samples = await pipeline.attentionSamples(
            in: range.lowerBound..<cappedUpper) else { return }
        do {
            // Text-only decode: identical conditions to the validated lab
            // battery (word timestamps degrade tiny's transcription).
            let transcript = try await recognizer.recognize(
                samples: AttentionAudioGain.normalized(samples),
                sampleRate: descriptor.sampleRate,
                wordTimestamps: false
            )
            guard generation == streamGeneration, state == .attentive else { return }
            if let match = VoiceCommandGrammar.match(text: transcript.text,
                                                     commands: commands()) {
                guard utteranceClosed else {
                    // Still speaking: wait for the pause. The command must be
                    // the whole utterance — dictation starts after the green
                    // light, never in the same breath.
                    return
                }
                guard !match.hasTrailingSpeech else {
                    DictationLog.write("numa: comando con dictado en la misma frase — rechazado (se enseña la señal)")
                    notice("Di «\(match.command.phrase)», espera la señal y dicta", 2.4)
                    return
                }
                await startVoiceSession(command: match.command,
                                        detectedRange: range.lowerBound..<cappedUpper,
                                        utteranceEnd: range.upperBound)
            } else if utteranceClosed {
                if VoiceCommandGrammar.mentionsCommandStart(transcript.text,
                                                            commands: commands()) {
                    DictationLog.write("numa: frase con inicio de comando pero sin comando completo")
                    notice("No te he entendido", 1.2)
                } else {
                    logUnmatchedSpeech(transcript, context: "sin comando")
                }
            }
        } catch {
            if generation == streamGeneration {
                DictationLog.write("numa: inferencia de atención falló — \(error.localizedDescription)")
                state = .unavailable("attentionModel")
                notice(error.localizedDescription, 2.4)
            }
        }
    }

    private func startVoiceSession(command: VoiceCommandSetting,
                                   detectedRange: Range<Int64>,
                                   utteranceEnd: Int64) async
    {
        // The session audio starts where the command utterance ended: the
        // transcript never contains the command, and anything spoken before
        // the green light appears is still in the ring, so nothing is lost.
        nextSessionID &+= 1
        let sessionID = nextSessionID
        guard let context = await pipeline.reserveVoiceAudio(
            sessionID: sessionID,
            commandPhrase: command.phrase,
            sessionAudioStartSample: utteranceEnd,
            commandWindow: detectedRange,
            estimatedCommandEndSample: utteranceEnd
        ) else {
            let metrics = await pipeline.metrics()
            DictationLog.write("numa: reserva de audio fallida — sesión de \(metrics.nextSample - detectedRange.lowerBound) muestras (ring \(descriptor.ringCapacitySamples))")
            return
        }
        DictationLog.write("numa: comando aceptado (\(command.action.rawValue)) — dictado por voz")
        streamGeneration &+= 1
        recognizer.reset()
        activeSoundTheme = soundTheme()
        soundPlayer.playActivation(theme: activeSoundTheme)
        commandRecognized(command.phrase)
        // beginDictation allocates the session id itself; hand it this one.
        nextSessionID -= 1
        switch command.action {
        case .record:
            await beginDictation(mode: .handsFree, source: .voiceCommand(context))
        }
    }

    /// Logs only that speech was recognized, never what it said: enough to
    /// separate "the microphone/model hears you" from "the words don't match".
    private func logUnmatchedSpeech(_ transcript: AttentionTranscript, context: String) {
        let length = transcript.text
            .trimmingCharacters(in: .whitespacesAndNewlines).count
        guard length > 0,
              Date().timeIntervalSince(lastUnmatchedSpeechLog) >= 5 else { return }
        lastUnmatchedSpeechLog = Date()
        DictationLog.write("numa: atención oyó habla \(context) (\(length) caracteres)")
    }

    private func attentionInferenceFinished() {
        attentionInferenceInFlight = false
        if attentionInferencePending {
            attentionInferencePending = false
            scheduleAttentionInference()
        }
    }

    private func clearSession() {
        activeSessionID = nil
        activeMode = nil
        pendingStop = nil
        abandonedUtteranceStart = nil
    }

    func dictationStateDidChange(_ dictationState: DictationState) {
        guard activeSessionID != nil else { return }
        switch dictationState {
        case .transcribing(let mode): state = .transcribing(mode)
        case .delivering(let mode): state = .delivering(mode)
        case .idle, .preparing, .recording, .failed: break
        }
    }
}
