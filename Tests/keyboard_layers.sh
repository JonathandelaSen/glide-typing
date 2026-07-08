#!/bin/zsh
# Layer system: letters/symbols/emoji layouts, shift state machine,
# long-press alternates and the emoji catalog.
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import AppKit

@MainActor
final class TapSpy: NSObject, KeyboardViewDelegate {
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

func chars(_ layout: KeyboardLayout) -> Set<Character> {
    Set(layout.keys.compactMap {
        if case .char(let c) = $0.action { return c }
        return nil
    })
}

func hasKey(_ layout: KeyboardLayout, _ action: KeyAction) -> Bool {
    layout.keys.contains { $0.action == action }
}

@main
struct Harness {
    @MainActor
    static func main() {
        // --- Letters layer -------------------------------------------------
        let letters = KeyboardLayout.build(for: .spanish)
        precondition(hasKey(letters, .shift))
        precondition(hasKey(letters, .layer(.symbols)))
        precondition(hasKey(letters, .layer(.emoji)))
        precondition(chars(letters).contains("ñ"))

        var shiftedState = LayoutState()
        shiftedState.shift = .on
        let shifted = KeyboardLayout.build(for: .spanish, state: shiftedState)
        precondition(chars(shifted).contains("Q"))
        precondition(chars(shifted).contains("Ñ"))
        precondition(!chars(shifted).contains("q"))
        precondition(chars(shifted).contains("1")) // digits unaffected

        // Accents ride on long-press alternates, cased with the layer.
        let a = letters.keys.first { $0.action == .char("a") }!
        precondition(a.alternates.contains("á"))
        let upperA = shifted.keys.first { $0.action == .char("A") }!
        precondition(upperA.alternates.contains("Á"))

        // --- Symbols layer -------------------------------------------------
        var symState = LayoutState()
        symState.layer = .symbols
        let symbols = KeyboardLayout.build(for: .spanish, state: symState)
        for needed: Character in ["@", "/", ":", "-", "_", "€", "¿", "¡"] {
            precondition(chars(symbols).contains(needed), "missing \(needed)")
        }
        precondition(hasKey(symbols, .tab))
        precondition(hasKey(symbols, .escape))
        precondition(hasKey(symbols, .arrow(.left)))
        precondition(hasKey(symbols, .symbolsPage(1)))

        symState.symbolsPage = 1
        let symbols2 = KeyboardLayout.build(for: .spanish, state: symState)
        precondition(chars(symbols2).contains("«"))
        precondition(hasKey(symbols2, .symbolsPage(0)))

        // --- Emoji layer ---------------------------------------------------
        var emojiState = LayoutState()
        emojiState.layer = .emoji
        emojiState.emojiCategory = 1
        let emoji = KeyboardLayout.build(for: .spanish, state: emojiState)
        let tabs = emoji.keys.filter {
            if case .emojiCategory = $0.action { return true }
            return false
        }
        precondition(tabs.count == EmojiCatalog.categoryCount)
        let cells = emoji.keys.filter {
            if case .text = $0.action { return true }
            return false
        }
        precondition(!cells.isEmpty && cells.count <= EmojiCatalog.perPage)
        precondition(hasKey(emoji, .layer(.letters)))
        precondition(hasKey(emoji, .backspace))

        // --- Every layer fits the 10×5 grid --------------------------------
        var gridStates: [LayoutState] = [LayoutState(), shiftedState, emojiState]
        for page in 0...1 {
            var s = LayoutState(); s.layer = .symbols; s.symbolsPage = page
            gridStates.append(s)
        }
        for state in gridStates {
            for language in [Language.spanish, .english] {
                let layout = KeyboardLayout.build(for: language, state: state)
                for key in layout.keys {
                    precondition(key.unitFrame.minX >= -0.001 && key.unitFrame.minY >= -0.001)
                    precondition(key.unitFrame.maxX <= layout.unitColumns + 0.001,
                                 "\(key.label) overflows")
                    precondition(key.unitFrame.maxY <= layout.unitRows + 0.001)
                }
            }
        }

        // --- View state machine --------------------------------------------
        let view = KeyboardView(language: .spanish)
        let spy = TapSpy()
        view.delegate = spy

        // Layout actions are absorbed; they never reach the delegate.
        view.dispatchTap(Key(action: .layer(.symbols), label: "", unitFrame: .zero))
        precondition(view.state.layer == .symbols)
        view.dispatchTap(Key(action: .layer(.letters), label: "", unitFrame: .zero))
        precondition(view.state.layer == .letters)
        precondition(spy.taps.isEmpty)

        // One-shot shift: raised by a tap, consumed by the letter it cased.
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        precondition(view.shiftState == .on)
        precondition(view.layout.keys.contains { $0.action == .char("Q") })
        view.dispatchTap(Key(action: .char("Q"), label: "Q", unitFrame: .zero))
        precondition(spy.taps == [.char("Q")])
        precondition(view.shiftState == .off)
        precondition(view.layout.keys.contains { $0.action == .char("q") })

        // Double-tap → caps lock; letters don't consume it.
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        precondition(view.shiftState == .capsLock)
        view.dispatchTap(Key(action: .char("A"), label: "A", unitFrame: .zero))
        precondition(view.shiftState == .capsLock)
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        precondition(view.shiftState == .off)

        // Auto-shift raises from .off and lowers only what it raised.
        view.setAutoShift(true)
        precondition(view.shiftState == .on)
        view.setAutoShift(false)
        precondition(view.shiftState == .off)
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        view.setAutoShift(false)
        precondition(view.shiftState == .on, "manual shift must survive auto-lowering")
        view.consumeShift()

        // The decoder's letter centers stay lowercase even when shifted.
        view.dispatchTap(Key(action: .shift, label: "", unitFrame: .zero))
        precondition(view.letterCenters["q"] != nil)
        precondition(view.letterCenters["Q"] == nil)
        view.consumeShift()

        // --- Emoji catalog ---------------------------------------------------
        for category in 0..<EmojiCatalog.categoryCount {
            let pages = EmojiCatalog.pageCount(category: category)
            precondition(pages >= 1)
            for page in 0..<pages {
                precondition(EmojiCatalog.page(category: category, page: page).count
                             <= EmojiCatalog.perPage)
            }
        }
        precondition(!EmojiCatalog.page(category: 999, page: 999).isEmpty) // clamps

        EmojiCatalog.recordRecent("🎉")
        EmojiCatalog.recordRecent("🚀")
        precondition(EmojiCatalog.recents.first == "🚀")
        EmojiCatalog.recordRecent("🎉")
        precondition(EmojiCatalog.recents.first == "🎉")
        precondition(EmojiCatalog.recents.filter { $0 == "🎉" }.count == 1)

        print("keyboard_layers OK")
    }
}
SWIFT

swiftc \
    -parse-as-library \
    "$repo_root/Sources/GlideBoard/KeyboardLayout.swift" \
    "$repo_root/Sources/GlideBoard/EmojiCatalog.swift" \
    "$repo_root/Sources/GlideBoard/KeyboardView.swift" \
    "$repo_root/Sources/GlideBoard/ComposerTextView.swift" \
    "$repo_root/Sources/GlideBoard/GestureDecoder.swift" \
    "$repo_root/Sources/GlideBoard/GestureRanking.swift" \
    "$repo_root/Sources/GlideBoard/Lexicon.swift" \
    "$repo_root/Sources/GlideBoard/DictationController.swift" \
    "$repo_root/Sources/GlideBoard/DictationButtonHitTesting.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/keyboard-layers"

"$work_dir/keyboard-layers"
