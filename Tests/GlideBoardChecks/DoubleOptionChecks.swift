import Foundation
@testable import GlideBoardCore

@MainActor
func doubleOptionChecks() async {
    Checks.shared.begin("Double-Option detector")

    let config = DoubleOptionDetector.Config(window: 0.4, maxHold: 0.4)

    func tap(_ detector: inout DoubleOptionDetector,
             down: TimeInterval, up: TimeInterval) -> Bool {
        _ = detector.ingest(.optionDown(at: down))
        return detector.ingest(.optionUp(at: up))
    }

    await Checks.shared.test("two clean taps inside the window trigger") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectTrue(tap(&detector, down: 0.25, up: 0.35))
    }

    await Checks.shared.test("a late second release does not trigger") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectFalse(tap(&detector, down: 0.45, up: 0.55))
    }

    await Checks.shared.test("a late tap starts a fresh sequence") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectFalse(tap(&detector, down: 1.00, up: 1.10))
        try expectTrue(tap(&detector, down: 1.20, up: 1.30))
    }

    await Checks.shared.test("a held Option key is not a tap") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        // Held past maxHold: ignored, and it also clears the pending tap.
        try expectFalse(tap(&detector, down: 0.15, up: 0.90))
        try expectFalse(tap(&detector, down: 1.00, up: 1.05))
        try expectTrue(tap(&detector, down: 1.10, up: 1.15))
    }

    await Checks.shared.test("another key between taps cancels") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectFalse(detector.ingest(.keyDown))
        try expectFalse(tap(&detector, down: 0.15, up: 0.25))
    }

    await Checks.shared.test("an Option chord (⌥E) never counts as a tap") {
        var detector = DoubleOptionDetector(config: config)
        _ = detector.ingest(.optionDown(at: 0.00))
        try expectFalse(detector.ingest(.keyDown))
        try expectFalse(detector.ingest(.optionUp(at: 0.10)))
        try expectFalse(tap(&detector, down: 0.15, up: 0.25))
    }

    await Checks.shared.test("a mouse click cancels the sequence") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectFalse(detector.ingest(.mouseDown))
        try expectFalse(tap(&detector, down: 0.15, up: 0.25))
    }

    await Checks.shared.test("another modifier cancels the sequence") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectFalse(detector.ingest(.otherModifier))
        try expectFalse(tap(&detector, down: 0.15, up: 0.25))
    }

    await Checks.shared.test("a trigger consumes the taps") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        try expectTrue(tap(&detector, down: 0.15, up: 0.25))
        // The third tap must not pair with the consumed second one.
        try expectFalse(tap(&detector, down: 0.30, up: 0.35))
        try expectTrue(tap(&detector, down: 0.40, up: 0.45))
    }

    await Checks.shared.test("reset clears a pending tap") {
        var detector = DoubleOptionDetector(config: config)
        try expectFalse(tap(&detector, down: 0.00, up: 0.10))
        detector.reset()
        try expectFalse(tap(&detector, down: 0.15, up: 0.25))
    }
}
