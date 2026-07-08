#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Foundation

final class EngineSpy: DictationEngine {
    var starts = 0
    var stops = 0
    var languages: [String] = []
    var transcript = "  Hola desde WhisperKit. \n"
    var waitBeforeStarting = false
    var startContinuation: CheckedContinuation<Void, Never>?

    func startRecording() async throws {
        starts += 1
        if waitBeforeStarting {
            await withCheckedContinuation { startContinuation = $0 }
        }
    }

    func stopRecordingAndTranscribe(language: String) async throws -> String {
        stops += 1
        languages.append(language)
        return transcript
    }

    func cancelRecording() {}

    func finishStarting() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

@main
struct DictationControllerCheck {
    @MainActor
    static func main() async {
        let engine = EngineSpy()
        var output: [String] = []
        var states: [DictationState] = []
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            output: { output.append($0) },
            stateChanged: { states.append($0) }
        )

        await controller.press()
        precondition(engine.starts == 1)
        precondition(controller.state == .recording)

        await controller.release()
        precondition(engine.stops == 1)
        precondition(engine.languages == ["es"])
        precondition(output == ["Hola desde WhisperKit."])
        precondition(controller.state == .idle)
        precondition(states == [.preparing, .recording, .transcribing, .idle])

        precondition(DictationInsertion.text(transcript: "voz", existingText: "texto") == " voz")
        precondition(DictationInsertion.text(transcript: "voz", existingText: "texto ") == "voz")
        precondition(DictationInsertion.text(transcript: "voz", existingText: "") == "voz")

        let quickReleaseEngine = EngineSpy()
        quickReleaseEngine.waitBeforeStarting = true
        let quickReleaseController = DictationController(
            engine: quickReleaseEngine,
            language: { "es" },
            output: { _ in },
            stateChanged: { _ in }
        )
        let pressTask = Task { await quickReleaseController.press() }
        while quickReleaseController.state != .preparing { await Task.yield() }
        await quickReleaseController.release()
        quickReleaseEngine.finishStarting()
        await pressTask.value
        precondition(quickReleaseEngine.stops == 1)
        precondition(quickReleaseController.state == .idle)
    }
}
SWIFT

swiftc \
    -parse-as-library \
    "$repo_root/Sources/GlideBoard/DictationController.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/dictation-controller"

"$work_dir/dictation-controller"
