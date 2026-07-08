import XCTest
import AppKit
@testable import GlideBoard

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
    func keyboardView(_ view: KeyboardView, didRequestInsert pressReturn: Bool) { insertReturns.append(pressReturn) }
    func keyboardViewDidRequestCopy(_ view: KeyboardView) {}
    func keyboardViewDidRequestTransform(_ view: KeyboardView) {}
    func keyboardViewDidResize(_ view: KeyboardView) {}
    func keyboardViewDidToggleHistory(_ view: KeyboardView) {}
    func keyboardViewDidToggleDictation(_ view: KeyboardView) { dictationToggleCount += 1 }
}

final class SwipeGestureTests: XCTestCase {
    /// An upward swipe (finger up = negative scroll dy on this setup) classifies
    /// as `.up` — the direction AppDelegate routes to Return when there is
    /// nothing to accept.
    @MainActor
    func testUpwardSwipeClassifiesAsUp() {
        let view = KeyboardView(language: .spanish)
        let spy = FlickSpy()
        view.delegate = spy

        view.classifySwipe(CGVector(dx: 0, dy: -60))

        XCTAssertEqual(spy.flicks, [.up])
    }

    /// A tiny movement below the gesture threshold is ignored (no accidental
    /// Return on a stray touch).
    @MainActor
    func testSubThresholdSwipeIsIgnored() {
        let view = KeyboardView(language: .spanish)
        let spy = FlickSpy()
        view.delegate = spy

        view.classifySwipe(CGVector(dx: 0, dy: -5))

        XCTAssertTrue(spy.flicks.isEmpty)
    }
}
