import Foundation

/// Pure state machine for the double-Option gesture: two clean tap cycles
/// (press then release, nothing else in between) whose releases land inside
/// the configured window. Timing comes in with the events so it is fully
/// testable without a real event stream.
struct DoubleOptionDetector {
    struct Config: Equatable {
        /// Maximum seconds between the two clean releases.
        var window: TimeInterval = 0.4
        /// A press held longer than this is a held Option, not a tap.
        var maxHold: TimeInterval = 0.4
    }

    enum Event: Equatable {
        case optionDown(at: TimeInterval)
        case optionUp(at: TimeInterval)
        /// Any other physical key, including autorepeats.
        case keyDown
        case mouseDown
        /// Another modifier (⌘⌃⇧) engaged.
        case otherModifier
    }

    private let config: Config
    private var pressStart: TimeInterval?
    /// Something else happened while Option was held: the cycle is a chord
    /// (⌥E, ⌥-click…), never a tap.
    private var chordSeen = false
    private var lastCleanRelease: TimeInterval?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one event; returns true when the gesture completed.
    mutating func ingest(_ event: Event) -> Bool {
        switch event {
        case .optionDown(let time):
            pressStart = time
            chordSeen = false
            if let last = lastCleanRelease, time - last > config.window {
                lastCleanRelease = nil
            }
            return false
        case .optionUp(let time):
            defer {
                pressStart = nil
                chordSeen = false
            }
            guard let start = pressStart, !chordSeen,
                  time - start <= config.maxHold else {
                lastCleanRelease = nil
                return false
            }
            if let last = lastCleanRelease, time - last <= config.window {
                lastCleanRelease = nil
                return true
            }
            lastCleanRelease = time
            return false
        case .keyDown, .mouseDown, .otherModifier:
            if pressStart != nil { chordSeen = true }
            lastCleanRelease = nil
            return false
        }
    }

    mutating func reset() {
        pressStart = nil
        chordSeen = false
        lastCleanRelease = nil
    }
}
