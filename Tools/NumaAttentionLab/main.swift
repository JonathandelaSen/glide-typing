import Foundation
@testable import GlideBoardCore

// Laboratorio de wake word: espera a que hables, graba la frase completa
// (con pre-roll, hasta que callas) y muestra qué transcribe el modelo de
// atención, en local y solo en esta terminal. Sirve para medir el recall de
// "Numa" o de cualquier frase candidata y comparar tamaños de modelo sin
// recompilar la app.
//
//   swift run NumaAttentionLab                            # tiny, "Numa, graba"
//   swift run NumaAttentionLab --model base               # modelo mayor
//   swift run NumaAttentionLab --phrase "Numa, escribe"   # candidata a comando
//   swift run NumaAttentionLab --no-gain                  # A/B sin normalizar
//   swift run NumaAttentionLab --prompt "…"               # bias manual distinto
//
// Cuando veas "🎙 habla cuando quieras", di la frase y calla. El corte por
// silencio hace imposible hablar "cuando no toca".

private func value(for flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag),
          index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []

    func append(_ frame: AudioFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func drain() -> [AudioFrame] {
        lock.lock()
        defer {
            frames.removeAll(keepingCapacity: true)
            lock.unlock()
        }
        return frames
    }
}

private let sampleRate = 16_000
/// 0.5 s antes de la primera voz, para no comerse el arranque de la frase.
private let preRollSamples = sampleRate / 2
/// 0.8 s de silencio cierran la frase.
private let trailingSilenceSamples = (sampleRate * 8) / 10
/// Nadie tarda más de 8 s en decir un wake word.
private let maximumUtteranceSamples = sampleRate * 8
/// Menos de 0.35 s de audio es un click o un golpe, no una frase.
private let minimumUtteranceSamples = (sampleRate * 35) / 100

@MainActor
private func run() async {
    let model = value(for: "--model") ?? "tiny"
    let gainEnabled = !CommandLine.arguments.contains("--no-gain")
    // The phrase under test doubles as the decoder bias, exactly like the
    // app builds its prompt from the configured commands.
    let phrase = value(for: "--phrase") ?? VoiceCommandSetting.defaults[0].phrase
    let commands = [VoiceCommandSetting(action: .record, phrase: phrase)]
    let prompt = value(for: "--prompt") ?? VoiceCommandGrammar.biasPrompt(for: commands)

    var descriptor = VoiceAttentionDescriptor.default(modelID: model)
    descriptor.biasPrompt = prompt
    let recognizer: VoiceAttentionRecognizing
    do {
        recognizer = try VoiceAttentionRecognizerFactory.make(descriptor: descriptor)
        print("Cargando el modelo \(model)…")
        try await recognizer.prepare()
    } catch {
        print("No se pudo preparar el modelo \(model): \(error.localizedDescription)")
        exit(1)
    }

    let capture = MicrophoneCaptureService()
    let sink = SampleSink()
    do {
        try await capture.start(generation: 1) { sink.append($0) }
    } catch {
        print("Micrófono no disponible: \(error.localizedDescription)")
        exit(1)
    }

    print("""

    Configuración: modelo \(model) · ganancia \(gainEnabled ? "ON" : "OFF") · \
    frase "\(phrase)" · prompt "\(prompt)"
    Listo. Di la frase y calla; al detectar ~1 s de silencio verás lo oído.
    Ctrl-C para salir.

    🎙 habla cuando quieras…
    """)

    var preRoll: [Float] = []
    var utterance: [Float] = []
    var recording = false
    var silentSamples = 0
    var maxRMS: Float = 0
    var round = 0

    while true {
        try? await Task.sleep(nanoseconds: 100_000_000)
        for frame in sink.drain() {
            if !recording {
                preRoll.append(contentsOf: frame.samples)
                if preRoll.count > preRollSamples {
                    preRoll.removeFirst(preRoll.count - preRollSamples)
                }
                guard frame.rms >= descriptor.voiceRMSFloor else { continue }
                recording = true
                utterance = preRoll
                silentSamples = 0
                maxRMS = frame.rms
                print("● grabando… (calla para cerrar la frase)")
                continue
            }

            utterance.append(contentsOf: frame.samples)
            maxRMS = max(maxRMS, frame.rms)
            if frame.rms < descriptor.voiceRMSFloor {
                silentSamples += frame.samples.count
            } else {
                silentSamples = 0
            }
            guard silentSamples >= trailingSilenceSamples
                    || utterance.count >= maximumUtteranceSamples else { continue }

            recording = false
            preRoll = []
            let samples = utterance
            utterance = []
            if samples.count < minimumUtteranceSamples {
                print("  (ruido breve ignorado)\n🎙 habla cuando quieras…")
                continue
            }
            round += 1
            let duration = Double(samples.count) / Double(sampleRate)
            let gain = gainEnabled ? AttentionAudioGain.gain(for: samples) : 1
            let audio = gain == 1 ? samples : samples.map { $0 * gain }
            do {
                let transcript = try await recognizer.recognize(
                    samples: audio,
                    sampleRate: descriptor.sampleRate,
                    wordTimestamps: false
                )
                let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let match = VoiceCommandGrammar.match(text: text, commands: commands)
                let verdict = match.map { "COMANDO ✓ (\($0.command.action.rawValue))" }
                    ?? "comando ✗"
                print(String(
                    format: "frase %2d · %.1f s · rms %.4f · ×%.1f · %@ · oído: \"%@\"",
                    round, duration, maxRMS, gain, verdict, text
                ))
            } catch {
                print("frase \(round) · error: \(error.localizedDescription)")
            }
            _ = sink.drain() // lo hablado durante la transcripción no cuenta
            print("🎙 habla cuando quieras…")
        }
    }
}

await run()
