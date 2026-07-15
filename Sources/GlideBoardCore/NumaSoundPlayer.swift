import AppKit
import Foundation

enum NumaSoundTheme: String, CaseIterable, Sendable {
    case crystal
    case pulse
    case organic
    case digital
    case silent
}

@MainActor
protocol NumaSoundPlaying: AnyObject {
    func playActivation(theme: NumaSoundTheme)
    func playFinish(theme: NumaSoundTheme) async
}

@MainActor
final class SilentNumaSoundPlayer: NumaSoundPlaying {
    func playActivation(theme: NumaSoundTheme) {}
    func playFinish(theme: NumaSoundTheme) async {}
}

@MainActor
private final class FinishSoundDelegate: NSObject, NSSoundDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var watchdog: DispatchWorkItem?

    init(continuation: CheckedContinuation<Void, Never>, timeout: TimeInterval) {
        self.continuation = continuation
        super.init()
        let work = DispatchWorkItem { [weak self] in self?.resolve() }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) { resolve() }

    func resolve() {
        watchdog?.cancel()
        watchdog = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}

@MainActor
final class NumaSoundPlayer: NumaSoundPlaying {
    private var activationSound: NSSound?
    private var finishSound: NSSound?
    private var finishDelegate: FinishSoundDelegate?

    func playActivation(theme: NumaSoundTheme) {
        guard theme != .silent,
              let sound = load(theme: theme, suffix: "activation") else { return }
        activationSound?.stop()
        activationSound = sound
        sound.play()
    }

    func playFinish(theme: NumaSoundTheme) async {
        guard theme != .silent,
              let sound = load(theme: theme, suffix: "finish") else { return }
        finishDelegate?.resolve()
        finishSound?.stop()
        finishSound = sound
        await withCheckedContinuation { continuation in
            let timeout = min(2.0, max(0.5, sound.duration + 0.5))
            let delegate = FinishSoundDelegate(continuation: continuation, timeout: timeout)
            finishDelegate = delegate
            sound.delegate = delegate
            if !sound.play() { delegate.resolve() }
        }
        finishDelegate = nil
        finishSound = nil
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private func load(theme: NumaSoundTheme, suffix: String) -> NSSound? {
        let name = "\(theme.rawValue)-\(suffix)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff",
                                        subdirectory: "NumaSounds") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }
}
