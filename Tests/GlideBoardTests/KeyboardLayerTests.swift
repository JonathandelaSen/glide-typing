import XCTest
import AppKit
@testable import GlideBoard

/// Minimal delegate that records the keys forwarded by the view, to verify
/// which taps reach the app and which are absorbed as layout changes.
private final class TapSpy: NSObject, KeyboardViewDelegate {
    var taps: [KeyAction] = []

    func keyboardView(_ view: KeyboardView, didTap key: Key) { taps.append(key.action) }
    func keyboardView(_ view: KeyboardView, didGlide points: [CGPoint]) {}
    func keyboardView(_ view: KeyboardView, didUpdateGlide points: [CGPoint]) {}
    func keyboardView(_ view: KeyboardView, didPickCandidate index: Int) {}
    func keyboardView(_ view: KeyboardView, didPickPrediction index: Int) {}
    func keyboardView(_ view: KeyboardView, didPickGhost text: String) {}
    func keyboardView(_ view: KeyboardView, didGlideSelect index: Int) {}
    func keyboardView(_ view: KeyboardView, didFlick direction: FlickDirection, long: Bool) {}
    func keyboardView(_ view: KeyboardView, didEdit action: EditAction) {}
    func keyboardView(_ view: KeyboardView, didSetHoverGlide enabled: Bool) {}
    func keyboardView(_ view: KeyboardView, didRepeatBackspaceByWord byWord: Bool) {}
    func keyboardView(_ view: KeyboardView, didRequestInsert pressReturn: Bool) {}
    func keyboardViewDidRequestCopy(_ view: KeyboardView) {}
    func keyboardViewDidRequestTransform(_ view: KeyboardView) {}
    func keyboardViewDidResize(_ view: KeyboardView) {}
    func keyboardViewDidToggleHistory(_ view: KeyboardView) {}
    func keyboardViewDidToggleDictation(_ view: KeyboardView) {}
}

final class KeyboardLayerTests: XCTestCase {

    private func chars(in layout: KeyboardLayout) -> Set<Character> {
        Set(layout.keys.compactMap {
            if case .char(let c) = $0.action { return c }
            return nil
        })
    }

    private func key(_ action: KeyAction, in layout: KeyboardLayout) -> Key? {
        layout.keys.first { $0.action == action }
    }

    // MARK: - Layout building

    func testLettersLayerHasLayerSwitchesAndShift() {
        let layout = KeyboardLayout.build(for: .spanish)
        XCTAssertNotNil(key(.shift, in: layout))
        XCTAssertNotNil(key(.layer(.symbols), in: layout))
        XCTAssertNotNil(key(.layer(.emoji), in: layout))
        XCTAssertTrue(chars(in: layout).contains("ñ"))
    }

    func testShiftUppercasesLetters() {
        var state = LayoutState()
        state.shift = .on
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        let set = chars(in: layout)
        XCTAssertTrue(set.contains("Q"))
        XCTAssertTrue(set.contains("Ñ"))
        XCTAssertFalse(set.contains("q"))
        // Digits are unaffected by shift.
        XCTAssertTrue(set.contains("1"))
    }

    func testSymbolsLayerCoversEmailAndURLCharacters() {
        var state = LayoutState()
        state.layer = .symbols
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        let set = chars(in: layout)
        for needed: Character in ["@", "/", ":", "-", "_", "€", "¿", "¡"] {
            XCTAssertTrue(set.contains(needed), "missing \(needed)")
        }
        XCTAssertNotNil(key(.tab, in: layout))
        XCTAssertNotNil(key(.escape, in: layout))
        XCTAssertNotNil(key(.arrow(.left), in: layout))
        XCTAssertNotNil(key(.symbolsPage(1), in: layout))
    }

    func testSymbolsSecondPage() {
        var state = LayoutState()
        state.layer = .symbols
        state.symbolsPage = 1
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        XCTAssertTrue(chars(in: layout).contains("«"))
        XCTAssertNotNil(key(.symbolsPage(0), in: layout))
    }

    func testEmojiLayerGrid() {
        var state = LayoutState()
        state.layer = .emoji
        state.emojiCategory = 1 // first fixed category (recents may be empty)
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        let tabs = layout.keys.filter {
            if case .emojiCategory = $0.action { return true }
            return false
        }
        XCTAssertEqual(tabs.count, EmojiCatalog.categoryCount)
        let emojis = layout.keys.filter {
            if case .text = $0.action { return true }
            return false
        }
        XCTAssertFalse(emojis.isEmpty)
        XCTAssertLessThanOrEqual(emojis.count, EmojiCatalog.perPage)
        XCTAssertNotNil(key(.backspace, in: layout))
        XCTAssertNotNil(key(.ret, in: layout))
        XCTAssertNotNil(key(.layer(.letters), in: layout))
    }

    func testAllLayersFitTheGrid() {
        var states: [LayoutState] = [LayoutState()]
        var shifted = LayoutState(); shifted.shift = .capsLock
        states.append(shifted)
        for page in 0...1 {
            var s = LayoutState(); s.layer = .symbols; s.symbolsPage = page
            states.append(s)
        }
        var emoji = LayoutState(); emoji.layer = .emoji; emoji.emojiCategory = 1
        states.append(emoji)

        for state in states {
            for language in [Language.spanish, .english] {
                let layout = KeyboardLayout.build(for: language, state: state)
                for key in layout.keys {
                    XCTAssertGreaterThanOrEqual(key.unitFrame.minX, -0.001)
                    XCTAssertGreaterThanOrEqual(key.unitFrame.minY, -0.001)
                    XCTAssertLessThanOrEqual(key.unitFrame.maxX, layout.unitColumns + 0.001,
                                             "\(key.label) overflows in \(state)")
                    XCTAssertLessThanOrEqual(key.unitFrame.maxY, layout.unitRows + 0.001)
                }
            }
        }
    }

    func testVowelAlternatesCarryAccents() {
        let layout = KeyboardLayout.build(for: .spanish)
        let a = layout.keys.first { $0.action == .char("a") }
        XCTAssertTrue(a?.alternates.contains("á") ?? false)

        var state = LayoutState(); state.shift = .on
        let shifted = KeyboardLayout.build(for: .spanish, state: state)
        let upperA = shifted.keys.first { $0.action == .char("A") }
        XCTAssertTrue(upperA?.alternates.contains("Á") ?? false)
    }

    // MARK: - View state machine

    @MainActor
    func testLayerSwitchIsAbsorbedByTheView() {
        let view = KeyboardView(language: .spanish)
        let spy = TapSpy()
        view.delegate = spy

        view.dispatchTap(Key(action: .layer(.symbols), label: "", unitFrame: .zero))
        XCTAssertEqual(view.state.layer, .symbols)
        view.dispatchTap(Key(action: .layer(.letters), label: "", unitFrame: .zero))
        XCTAssertEqual(view.state.layer, .letters)
        XCTAssertTrue(spy.taps.isEmpty, "layout actions must not reach the delegate")
    }

    @MainActor
    func testOneShotShiftIsConsumedByALetter() {
        let view = KeyboardView(language: .spanish)
        let spy = TapSpy()
        view.delegate = spy

        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        XCTAssertEqual(view.shiftState, .on)
        // The shifted layout carries uppercase keys.
        XCTAssertTrue(view.layout.keys.contains { $0.action == .char("Q") })

        view.dispatchTap(Key(action: .char("Q"), label: "Q", unitFrame: .zero))
        XCTAssertEqual(spy.taps, [.char("Q")])
        XCTAssertEqual(view.shiftState, .off)
        XCTAssertTrue(view.layout.keys.contains { $0.action == .char("q") })
    }

    @MainActor
    func testDoubleTapShiftEngagesCapsLock() {
        let view = KeyboardView(language: .spanish)
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        XCTAssertEqual(view.shiftState, .capsLock)
        // Caps lock survives letters and only a further tap clears it.
        view.dispatchTap(Key(action: .char("A"), label: "A", unitFrame: .zero))
        XCTAssertEqual(view.shiftState, .capsLock)
    }

    @MainActor
    func testAutoShiftNeverLowersAManualShift() {
        let view = KeyboardView(language: .spanish)
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        view.setAutoShift(false)
        XCTAssertEqual(view.shiftState, .on, "manual shift must survive auto-lowering")
        view.setAutoShift(true) // no-op: already on
        view.consumeShift()
        XCTAssertEqual(view.shiftState, .off)
        view.setAutoShift(true)
        XCTAssertEqual(view.shiftState, .on)
        view.setAutoShift(false)
        XCTAssertEqual(view.shiftState, .off, "auto shift lowers what it raised")
    }

    // MARK: - Emoji catalog

    func testEmojiCatalogPaging() {
        for category in 0..<EmojiCatalog.categoryCount {
            let pages = EmojiCatalog.pageCount(category: category)
            XCTAssertGreaterThanOrEqual(pages, 1)
            for page in 0..<pages {
                XCTAssertLessThanOrEqual(
                    EmojiCatalog.page(category: category, page: page).count,
                    EmojiCatalog.perPage)
            }
        }
        // Out-of-range requests clamp instead of crashing.
        XCTAssertFalse(EmojiCatalog.page(category: 999, page: 999).isEmpty)
    }

    func testEmojiRecentsMoveToFront() {
        EmojiCatalog.recordRecent("🎉")
        EmojiCatalog.recordRecent("🚀")
        XCTAssertEqual(EmojiCatalog.recents.first, "🚀")
        EmojiCatalog.recordRecent("🎉")
        XCTAssertEqual(EmojiCatalog.recents.first, "🎉")
        XCTAssertEqual(EmojiCatalog.recents.filter { $0 == "🎉" }.count, 1)
    }
}
