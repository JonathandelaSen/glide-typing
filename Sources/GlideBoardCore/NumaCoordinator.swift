import Foundation

enum NumaState: Equatable {
    case stopped
    case starting
    case attentive
    case awaitingCommand
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
    private let commandRecognized: () -> Void

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
    private var wakeSessionAudioStartSample: Int64?
    private var commandDeadlineSample: Int64?
    private var userAttentionEnabled = true
    private var suspended = false
    /// Tracks the physical key so a tap whose release arrives before
    /// `beginDictation` has run still stops the session it started.
    private var pushToTalkHeld = false
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
         commandRecognized: @escaping () -> Void = {})
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
                self.pipeline.ingest(samples: frame.samples)
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
            notice(error.localizedDescription, 2.4)
            return
        }

        do {
            try await recognizer.prepare()
            attentionPrepared = true
        } catch {
            attentionPrepared = false
            if state == .attentive {
                captureGeneration &+= 1
                capture.stop(generation: captureGeneration)
                state = .unavailable("attentionModel")
            }
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
        silenceDetector = HandsFreeSilenceDetector()
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
                    self.pipeline.ingest(samples: frame.samples)
                    Task { @MainActor [weak self] in self?.received(frame) }
                }
            } catch {
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
            await pipeline.cancelDictation(sessionID: sessionID)
            await soundPlayer.playFinish(theme: activeSoundTheme)
            controller.cancel(sessionID: sessionID)
            clearSession()
            await rearmAfterSession()
            return
        }
        guard let samples = await pipeline.finishDictation(sessionID: sessionID) else {
            // The pipeline lost the session (a pause/suspend raced us). Never
            // leave the coordinator parked in .recording with a dead session.
            if activeSessionID == sessionID {
                controller.cancel(sessionID: sessionID)
                clearSession()
                await rearmAfterSession()
            }
            return
        }
        await soundPlayer.playFinish(theme: activeSoundTheme)
        state = .transcribing(mode)
        let outcome = await controller.stop(sessionID: sessionID, reason: reason, samples: samples)
        guard activeSessionID == sessionID else { return }
        if outcome == .unsafeVoicePrefix {
            notice("No he podido separar la orden del dictado", 2.4)
        }
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

        guard attentionPrepared, state == .attentive || state == .awaitingCommand else { return }
        samplesSinceAttentionWindow += frame.samples.count
        guard samplesSinceAttentionWindow >= descriptor.hopSamples else { return }
        samplesSinceAttentionWindow %= descriptor.hopSamples
        scheduleAttentionInference()
    }

    private func scheduleAttentionInference() {
        guard !attentionInferenceInFlight else {
            attentionInferencePending = true
            return
        }
        attentionInferenceInFlight = true
        let generation = streamGeneration
        let wantsWords = state == .awaitingCommand
        Task { @MainActor [weak self] in
            guard let self,
                  let window = await pipeline.ringSnapshot(length: descriptor.windowSamples) else {
                self?.attentionInferenceFinished()
                return
            }
            do {
                let transcript = try await recognizer.recognize(
                    samples: window.samples,
                    sampleRate: descriptor.sampleRate,
                    wordTimestamps: wantsWords
                )
                guard generation == streamGeneration else {
                    attentionInferenceFinished()
                    return
                }
                await processAttention(transcript, window: window.range)
            } catch {
                if generation == streamGeneration {
                    state = .unavailable("attentionModel")
                    notice(error.localizedDescription, 2.4)
                }
            }
            attentionInferenceFinished()
        }
    }

    private func processAttention(_ transcript: AttentionTranscript,
                                  window: Range<Int64>) async
    {
        switch state {
        case .attentive:
            guard VoiceAttentionIntentMatcher.containsWakeWord(transcript.text) else { return }
            let metrics = await pipeline.metrics()
            wakeSessionAudioStartSample = window.lowerBound
            commandDeadlineSample = metrics.nextSample + 48_000
            streamGeneration &+= 1
            recognizer.reset()
            activeSoundTheme = soundTheme()
            soundPlayer.playActivation(theme: activeSoundTheme)
            state = .awaitingCommand
        case .awaitingCommand:
            guard let commandEnd = VoiceAttentionIntentMatcher.commandEndTime(transcript),
                  let deadline = commandDeadlineSample,
                  let sessionStart = wakeSessionAudioStartSample else { return }
            let absoluteEnd = window.lowerBound + Int64(commandEnd * 16_000)
            guard absoluteEnd <= deadline else { return }
            nextSessionID &+= 1
            let sessionID = nextSessionID
            guard let context = await pipeline.reserveVoiceAudio(
                sessionID: sessionID,
                wakeWordID: "numa",
                sessionAudioStartSample: sessionStart,
                commandWindow: window,
                estimatedCommandEndSample: absoluteEnd
            ) else { return }
            commandRecognized()
            nextSessionID -= 1
            await beginDictation(mode: .handsFree, source: .voiceCommand(context))
        default:
            break
        }
    }

    private func attentionInferenceFinished() {
        attentionInferenceInFlight = false
        if attentionInferencePending {
            attentionInferencePending = false
            scheduleAttentionInference()
            return
        }
        guard state == .awaitingCommand, let deadline = commandDeadlineSample else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let next = await pipeline.metrics().nextSample
            guard state == .awaitingCommand, next >= deadline else { return }
            wakeSessionAudioStartSample = nil
            commandDeadlineSample = nil
            streamGeneration &+= 1
            recognizer.reset()
            state = .attentive
            notice("No te he entendido", 1.2)
        }
    }

    private func clearSession() {
        activeSessionID = nil
        activeMode = nil
        pendingStop = nil
        wakeSessionAudioStartSample = nil
        commandDeadlineSample = nil
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
