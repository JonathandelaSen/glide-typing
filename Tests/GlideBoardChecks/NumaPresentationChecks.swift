import Foundation
@testable import GlideBoardCore

@MainActor
func numaPresentationChecks() async {
    let c = Checks.shared
    c.begin("Numa presentation")

    await c.test("overlay is centered 26 points above the visible edge") {
        let origin = OverlayPositioner.origin(
            visibleFrame: CGRect(x: 100, y: 50, width: 1_000, height: 700),
            panelSize: CGSize(width: 330, height: 76))
        try expectEqual(origin, CGPoint(x: 435, y: 76))
    }

    await c.test("screen selection uses the containing frame") {
        let frames = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_200, height: 900),
        ]
        try expectEqual(ActiveScreenResolver.screenIndex(
            containing: CGPoint(x: 1_400, y: 400), frames: frames), 1)
        try expectNil(ActiveScreenResolver.screenIndex(
            containing: CGPoint(x: -10, y: 400), frames: frames))
    }

    await c.test("RMS maps silence to zero and real signal above zero") {
        try expectEqual(NumaSignalLevel.normalized(rms: 0), 0)
        try expectTrue(NumaSignalLevel.normalized(rms: 0.1) > 0.5)
        try expectEqual(NumaSignalLevel.normalized(rms: 1), 1)
    }
}
