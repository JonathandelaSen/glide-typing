import AppKit
@testable import GlideBoardCore

/// Captures the gesture callbacks fired by KeyboardView so we can assert what
/// an upward two-finger swipe routes to.
private final class FlickSpy: NSObject, KeyboardViewDelegate {
    var flicks: [FlickDirection] = []
    var insertReturns: [Bool] = []
    var dictationToggleCount = 0

    func keyboardView(_ view: KeyboardView, didTap key: Key) {}
    func keyboardView(_ view: KeyboardView, didGlide points: [CGPoint]) {}
    func keyboardView(_ view: KeyboardView, didUpdateGlide points: [CGPoint]) {}
    func keyboardView(_ view: KeyboardView, didPickCandidate index: Int) {}
    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int) {}
    func keyboardView(_ view: KeyboardView, didPickGhost text: String) {}
    func keyboardView(_ view: KeyboardView, didGlideSelect index: Int) {}
    func keyboardView(_ view: KeyboardView, didFlick direction: FlickDirection, long: Bool) {
        flicks.append(direction)
    }
    func keyboardView(_ view: KeyboardView, didEdit action: EditAction) {}
    func keyboardView(_ view: KeyboardView, didSetHoverGlide enabled: Bool) {}
    func keyboardView(_ view: KeyboardView, didRepeatBackspaceByWord byWord: Bool) {}
    func keyboardView(_ view: KeyboardView, didRequestInsert pressReturn: Bool) {
        insertReturns.append(pressReturn)
    }
    func keyboardViewDidRequestCopy(_ view: KeyboardView) {}
    func keyboardViewDidRequestTransform(_ view: KeyboardView) {}
    func keyboardViewDidResize(_ view: KeyboardView) {}
    func keyboardViewDidToggleHistory(_ view: KeyboardView) {}
    func keyboardViewDidToggleDictation(_ view: KeyboardView) { dictationToggleCount += 1 }
}

@MainActor
func swipeGestureChecks() async {
    let c = Checks.shared
    c.begin("Swipe gestures")

    await c.test("an upward swipe classifies as .up") {
        let view = KeyboardView(language: .spanish)
        let spy = FlickSpy()
        view.delegate = spy
        // Finger up = negative scroll dy on this setup; AppDelegate routes
        // .up to Return when there is nothing to accept.
        view.classifySwipe(CGVector(dx: 0, dy: -60))
        try expectEqual(spy.flicks, [.up])
    }

    await c.test("a sub-threshold movement is ignored") {
        let view = KeyboardView(language: .spanish)
        let spy = FlickSpy()
        view.delegate = spy
        view.classifySwipe(CGVector(dx: 0, dy: -5))
        try expectTrue(spy.flicks.isEmpty, "no accidental Return on a stray touch")
    }

    await c.test("horizontal swipes classify by dominant axis") {
        let view = KeyboardView(language: .spanish)
        let spy = FlickSpy()
        view.delegate = spy
        view.classifySwipe(CGVector(dx: 80, dy: 4))
        view.classifySwipe(CGVector(dx: -80, dy: -4))
        try expectEqual(spy.flicks.count, 2)
        try expectTrue(spy.flicks[0] != spy.flicks[1],
                       "opposite swipes must classify differently: \(spy.flicks)")
    }
}
