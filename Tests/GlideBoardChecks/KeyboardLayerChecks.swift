import AppKit
@testable import GlideBoardCore

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

@MainActor
func keyboardLayerChecks() async {
    let c = Checks.shared
    c.begin("Keyboard layers")

    func chars(in layout: KeyboardLayout) -> Set<Character> {
        Set(layout.keys.compactMap {
            if case .char(let ch) = $0.action { return ch }
            return nil
        })
    }

    func key(_ action: KeyAction, in layout: KeyboardLayout) -> Key? {
        layout.keys.first { $0.action == action }
    }

    await c.test("letters layer has layer switches, shift and ñ") {
        let layout = KeyboardLayout.build(for: .spanish)
        _ = try unwrap(key(.shift, in: layout))
        _ = try unwrap(key(.layer(.symbols), in: layout))
        _ = try unwrap(key(.layer(.emoji), in: layout))
        try expectTrue(chars(in: layout).contains("ñ"))
    }

    await c.test("shift uppercases letters but not digits") {
        var state = LayoutState()
        state.shift = .on
        let set = chars(in: KeyboardLayout.build(for: .spanish, state: state))
        try expectTrue(set.contains("Q"))
        try expectTrue(set.contains("Ñ"))
        try expectFalse(set.contains("q"))
        try expectTrue(set.contains("1"))
    }

    await c.test("symbols layer covers email and URL characters") {
        var state = LayoutState()
        state.layer = .symbols
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        let set = chars(in: layout)
        for needed: Character in ["@", "/", ":", "-", "_", "€", "¿", "¡"] {
            try expectTrue(set.contains(needed), "missing \(needed)")
        }
        _ = try unwrap(key(.tab, in: layout))
        _ = try unwrap(key(.escape, in: layout))
        _ = try unwrap(key(.arrow(.left), in: layout))
        _ = try unwrap(key(.symbolsPage(1), in: layout))
    }

    await c.test("symbols second page exists and links back") {
        var state = LayoutState()
        state.layer = .symbols
        state.symbolsPage = 1
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        try expectTrue(chars(in: layout).contains("«"))
        _ = try unwrap(key(.symbolsPage(0), in: layout))
    }

    await c.test("emoji layer builds its grid with tabs and controls") {
        var state = LayoutState()
        state.layer = .emoji
        state.emojiCategory = 1 // first fixed category (recents may be empty)
        let layout = KeyboardLayout.build(for: .spanish, state: state)
        let tabs = layout.keys.filter {
            if case .emojiCategory = $0.action { return true }
            return false
        }
        try expectEqual(tabs.count, EmojiCatalog.categoryCount)
        let emojis = layout.keys.filter {
            if case .text = $0.action { return true }
            return false
        }
        try expectFalse(emojis.isEmpty)
        try expectTrue(emojis.count <= EmojiCatalog.perPage)
        _ = try unwrap(key(.backspace, in: layout))
        _ = try unwrap(key(.ret, in: layout))
        _ = try unwrap(key(.layer(.letters), in: layout))
    }

    await c.test("every layer fits the unit grid in both languages") {
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
                    try expectTrue(key.unitFrame.minX >= -0.001)
                    try expectTrue(key.unitFrame.minY >= -0.001)
                    try expectTrue(key.unitFrame.maxX <= layout.unitColumns + 0.001,
                                   "\(key.label) overflows in \(state)")
                    try expectTrue(key.unitFrame.maxY <= layout.unitRows + 0.001)
                }
            }
        }
    }

    await c.test("vowel alternates carry accents in both cases") {
        let layout = KeyboardLayout.build(for: .spanish)
        let a = layout.keys.first { $0.action == .char("a") }
        try expectTrue(a?.alternates.contains("á") ?? false)

        var state = LayoutState(); state.shift = .on
        let shifted = KeyboardLayout.build(for: .spanish, state: state)
        let upperA = shifted.keys.first { $0.action == .char("A") }
        try expectTrue(upperA?.alternates.contains("Á") ?? false)
    }

    await c.test("layer switches are absorbed by the view") {
        let view = KeyboardView(language: .spanish)
        let spy = TapSpy()
        view.delegate = spy
        view.dispatchTap(Key(action: .layer(.symbols), label: "", unitFrame: .zero))
        try expectEqual(view.state.layer, .symbols)
        view.dispatchTap(Key(action: .layer(.letters), label: "", unitFrame: .zero))
        try expectEqual(view.state.layer, .letters)
        try expectTrue(spy.taps.isEmpty, "layout actions must not reach the delegate")
    }

    await c.test("one-shot shift is consumed by a letter") {
        let view = KeyboardView(language: .spanish)
        let spy = TapSpy()
        view.delegate = spy
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        try expectEqual(view.shiftState, .on)
        try expectTrue(view.layout.keys.contains { $0.action == .char("Q") })
        view.dispatchTap(Key(action: .char("Q"), label: "Q", unitFrame: .zero))
        try expectEqual(spy.taps, [.char("Q")])
        try expectEqual(view.shiftState, .off)
        try expectTrue(view.layout.keys.contains { $0.action == .char("q") })
    }

    await c.test("double-tap shift engages caps lock") {
        let view = KeyboardView(language: .spanish)
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        try expectEqual(view.shiftState, .capsLock)
        view.dispatchTap(Key(action: .char("A"), label: "A", unitFrame: .zero))
        try expectEqual(view.shiftState, .capsLock, "caps lock survives letters")
    }

    await c.test("auto shift never lowers a manual shift") {
        let view = KeyboardView(language: .spanish)
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        view.setAutoShift(false)
        try expectEqual(view.shiftState, .on, "manual shift must survive auto-lowering")
        view.setAutoShift(true) // no-op: already on
        view.consumeShift()
        try expectEqual(view.shiftState, .off)
        view.setAutoShift(true)
        try expectEqual(view.shiftState, .on)
        view.setAutoShift(false)
        try expectEqual(view.shiftState, .off, "auto shift lowers what it raised")
    }

    await c.test("emoji catalog pages stay within the grid and clamp") {
        for category in 0..<EmojiCatalog.categoryCount {
            let pages = EmojiCatalog.pageCount(category: category)
            try expectTrue(pages >= 1)
            for page in 0..<pages {
                try expectTrue(EmojiCatalog.page(category: category, page: page).count
                               <= EmojiCatalog.perPage)
            }
        }
        try expectFalse(EmojiCatalog.page(category: 999, page: 999).isEmpty,
                        "out-of-range requests clamp instead of crashing")
    }

    await c.test("emoji recents move to the front without duplicates") {
        EmojiCatalog.recordRecent("🎉")
        EmojiCatalog.recordRecent("🚀")
        try expectEqual(EmojiCatalog.recents.first, "🚀")
        EmojiCatalog.recordRecent("🎉")
        try expectEqual(EmojiCatalog.recents.first, "🎉")
        try expectEqual(EmojiCatalog.recents.filter { $0 == "🎉" }.count, 1)
    }
}
