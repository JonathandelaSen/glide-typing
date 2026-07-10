import AppKit

/// The pages the keyboard can show. Glide only lives on `.letters`; the other
/// layers reuse the same grid, hit-testing and drawing pipeline.
enum KeyboardLayer: Equatable {
    case letters
    case symbols
    case emoji
}

enum ShiftState: Equatable {
    case off
    /// One-shot: capitalizes the next input, then drops back to `.off`.
    case on
    /// Sticky (double-tap on shift): stays until shift is tapped again.
    case capsLock

    var isActive: Bool { self != .off }
}

enum ArrowKey: Equatable {
    case left, right, up, down
}

enum KeyAction: Equatable {
    case char(Character)
    /// Multi-character output: emoji, "…", typographic pairs.
    case text(String)
    case space
    case backspace
    case ret
    case tab
    case escape
    case arrow(ArrowKey)
    case shift
    case layer(KeyboardLayer)
    /// Jump to an absolute page within the symbols layer (0 = ?123, 1 = #+=).
    case symbolsPage(Int)
    case emojiCategory(Int)
    /// Page within the current emoji category, relative (-1 / +1).
    case emojiPageDelta(Int)
    case language
    case hide
}

struct Key {
    let action: KeyAction
    let label: String
    /// Frame in unit-grid coordinates (1 unit = one standard key cell).
    let unitFrame: CGRect
    /// Long-press variants (accents, inverted punctuation…), already cased
    /// for the shift state the layout was built with.
    var alternates: [String] = []

    var isLetter: Bool {
        if case .char(let c) = action, c.isLetter { return true }
        return false
    }
    var letter: Character? {
        if case .char(let c) = action, c.isLetter { return c }
        return nil
    }
}

enum Language: String {
    case english = "EN"
    case spanish = "ES"

    var wordFile: String {
        switch self {
        case .english: return "en_words"
        case .spanish: return "es_words"
        }
    }

    func toggled() -> Language { self == .english ? .spanish : .english }
}

/// Everything that decides which keys are on screen right now. Owned by
/// KeyboardView; the layout is a pure function of language + this state.
struct LayoutState: Equatable {
    var layer: KeyboardLayer = .letters
    var shift: ShiftState = .off
    var symbolsPage: Int = 0
    var emojiCategory: Int = 0
    var emojiPage: Int = 0
}

/// Long-press variants per base key. Keyed by the lowercase character; the
/// layout uppercases them when built with shift active.
enum KeyAlternates {
    private static let map: [Character: [String]] = [
        "a": ["á", "à", "ä", "â", "ã", "å"],
        "e": ["é", "è", "ë", "ê"],
        "i": ["í", "ì", "ï", "î"],
        "o": ["ó", "ò", "ö", "ô", "õ"],
        "u": ["ú", "ù", "ü", "û"],
        "n": ["ñ"],
        "c": ["ç"],
        "s": ["ß"],
        "y": ["ý"],
        "?": ["¿", "!", "¡"],
        "!": ["¡", "?", "¿"],
        ".": ["…", ":", ";"],
        ",": [";", ":"],
        "'": ["\"", "‘", "’", "`"],
        "\"": ["«", "»", "“", "”"],
        "-": ["–", "—", "·"],
        "$": ["€", "£", "¥", "¢"],
        "€": ["$", "£", "¥", "¢"],
        "0": ["°"]
    ]

    static func alternates(for ch: Character, shifted: Bool) -> [String] {
        guard let alts = map[Character(String(ch).lowercased())] else { return [] }
        return shifted ? alts.map { $0.uppercased() } : alts
    }
}

struct KeyboardLayout {
    let keys: [Key]
    let unitColumns: CGFloat = 10
    let unitRows: CGFloat = 5

    static func build(for language: Language,
                      state: LayoutState = LayoutState()) -> KeyboardLayout {
        switch state.layer {
        case .letters: return lettersLayer(language: language, shift: state.shift)
        case .symbols: return symbolsLayer(page: state.symbolsPage)
        case .emoji: return emojiLayer(state: state)
        }
    }

    // MARK: - Shared rows

    /// A row of single-character keys, each 1 unit wide.
    private static func charRow(_ chars: String, row: CGFloat, offset: CGFloat,
                                shifted: Bool = false, into keys: inout [Key]) {
        for (i, ch) in chars.enumerated() {
            let cased: Character = shifted ? Character(String(ch).uppercased()) : ch
            keys.append(Key(action: .char(cased),
                            label: String(cased),
                            unitFrame: CGRect(x: offset + CGFloat(i), y: row, width: 1, height: 1),
                            alternates: KeyAlternates.alternates(for: ch, shifted: shifted)))
        }
    }

    private static func backspaceKey(row: CGFloat) -> Key {
        Key(action: .backspace, label: "⌫",
            unitFrame: CGRect(x: 8.25, y: row, width: 1.75, height: 1))
    }

    private static func hideKey(row: CGFloat) -> Key {
        Key(action: .hide, label: "✕",
            unitFrame: CGRect(x: 0, y: row, width: 0.9, height: 1))
    }

    // MARK: - Letters

    private static func lettersLayer(language: Language, shift: ShiftState) -> KeyboardLayout {
        var keys: [Key] = []
        let shifted = shift.isActive

        charRow("1234567890", row: 0, offset: 0, into: &keys)
        charRow("qwertyuiop", row: 1, offset: 0, shifted: shifted, into: &keys)
        switch language {
        case .english:
            charRow("asdfghjkl", row: 2, offset: 0.5, shifted: shifted, into: &keys)
        case .spanish:
            charRow("asdfghjklñ", row: 2, offset: 0, shifted: shifted, into: &keys)
        }
        keys.append(Key(action: .shift, label: shift == .capsLock ? "⇪" : "⇧",
                        unitFrame: CGRect(x: 0, y: 3, width: 0.95, height: 1)))
        charRow("zxcvbnm", row: 3, offset: 1.0, shifted: shifted, into: &keys)
        keys.append(backspaceKey(row: 3))

        keys.append(hideKey(row: 4))
        keys.append(Key(action: .layer(.symbols), label: "?123",
                        unitFrame: CGRect(x: 0.9, y: 4, width: 1.1, height: 1)))
        keys.append(Key(action: .layer(.emoji), label: "😊",
                        unitFrame: CGRect(x: 2.0, y: 4, width: 0.9, height: 1)))
        keys.append(Key(action: .language, label: language.rawValue,
                        unitFrame: CGRect(x: 2.9, y: 4, width: 0.9, height: 1)))
        keys.append(Key(action: .char(","), label: ",",
                        unitFrame: CGRect(x: 3.8, y: 4, width: 0.7, height: 1),
                        alternates: KeyAlternates.alternates(for: ",", shifted: false)))
        keys.append(Key(action: .space, label: "espacio",
                        unitFrame: CGRect(x: 4.5, y: 4, width: 2.9, height: 1)))
        keys.append(Key(action: .char("."), label: ".",
                        unitFrame: CGRect(x: 7.4, y: 4, width: 0.7, height: 1),
                        alternates: KeyAlternates.alternates(for: ".", shifted: false)))
        keys.append(Key(action: .char("?"), label: "?",
                        unitFrame: CGRect(x: 8.1, y: 4, width: 0.7, height: 1),
                        alternates: KeyAlternates.alternates(for: "?", shifted: false)))
        keys.append(Key(action: .ret, label: "⏎",
                        unitFrame: CGRect(x: 8.8, y: 4, width: 1.2, height: 1)))

        return KeyboardLayout(keys: keys)
    }

    // MARK: - Symbols

    /// Two pages, iOS-style: "?123" covers everyday punctuation and currency;
    /// "#+=" the long tail. The bottom row adds field navigation (tab, esc,
    /// arrows) — the pieces a pointer-driven keyboard otherwise can't reach.
    private static let symbolPages: [(rows: [String], extras: [String])] = [
        (rows: ["1234567890",
                "@#$€%&/()=",
                "-_:;\"'+*!?"],
         extras: [",", ".", "<", ">", "¿", "¡"]),
        (rows: ["1234567890",
                "~`|·±×÷^°§",
                "\\[]{}«»¢£¥"],
         extras: ["—", "–", "…", "©", "®", "™"])
    ]

    private static func symbolsLayer(page rawPage: Int) -> KeyboardLayout {
        let page = min(max(0, rawPage), symbolPages.count - 1)
        let content = symbolPages[page]
        var keys: [Key] = []

        for (rowIndex, rowChars) in content.rows.enumerated() {
            charRow(rowChars, row: CGFloat(rowIndex), offset: 0, into: &keys)
        }

        let other = (page + 1) % symbolPages.count
        keys.append(Key(action: .symbolsPage(other), label: page == 0 ? "#+=" : "123",
                        unitFrame: CGRect(x: 0, y: 3, width: 0.95, height: 1)))
        for (i, extra) in content.extras.enumerated() {
            let ch = Character(extra)
            keys.append(Key(action: .char(ch), label: extra,
                            unitFrame: CGRect(x: 1.0 + CGFloat(i) * 1.2, y: 3, width: 1.2, height: 1),
                            alternates: KeyAlternates.alternates(for: ch, shifted: false)))
        }
        keys.append(backspaceKey(row: 3))

        keys.append(hideKey(row: 4))
        keys.append(Key(action: .layer(.letters), label: "ABC",
                        unitFrame: CGRect(x: 0.9, y: 4, width: 1.1, height: 1)))
        keys.append(Key(action: .tab, label: "⇥",
                        unitFrame: CGRect(x: 2.0, y: 4, width: 0.7, height: 1)))
        keys.append(Key(action: .escape, label: "esc",
                        unitFrame: CGRect(x: 2.7, y: 4, width: 0.7, height: 1)))
        keys.append(Key(action: .arrow(.left), label: "←",
                        unitFrame: CGRect(x: 3.4, y: 4, width: 0.7, height: 1)))
        keys.append(Key(action: .arrow(.down), label: "↓",
                        unitFrame: CGRect(x: 4.1, y: 4, width: 0.7, height: 1)))
        keys.append(Key(action: .arrow(.up), label: "↑",
                        unitFrame: CGRect(x: 4.8, y: 4, width: 0.7, height: 1)))
        keys.append(Key(action: .arrow(.right), label: "→",
                        unitFrame: CGRect(x: 5.5, y: 4, width: 0.7, height: 1)))
        keys.append(Key(action: .space, label: "espacio",
                        unitFrame: CGRect(x: 6.2, y: 4, width: 2.6, height: 1)))
        keys.append(Key(action: .ret, label: "⏎",
                        unitFrame: CGRect(x: 8.8, y: 4, width: 1.2, height: 1)))

        return KeyboardLayout(keys: keys)
    }

    // MARK: - Emoji

    /// Row 0: category tabs. Rows 1–3: a 10×3 page of the selected category.
    /// Row 4: back to letters, paging arrows, space, backspace and return.
    private static func emojiLayer(state: LayoutState) -> KeyboardLayout {
        var keys: [Key] = []

        let tabCount = EmojiCatalog.categoryCount
        let tabWidth = 10.0 / CGFloat(tabCount)
        for i in 0..<tabCount {
            keys.append(Key(action: .emojiCategory(i), label: EmojiCatalog.icon(at: i),
                            unitFrame: CGRect(x: CGFloat(i) * tabWidth, y: 0,
                                              width: tabWidth, height: 1)))
        }

        let emojis = EmojiCatalog.page(category: state.emojiCategory, page: state.emojiPage)
        for (i, emoji) in emojis.enumerated() {
            let row = 1 + CGFloat(i / EmojiCatalog.gridColumns)
            let col = CGFloat(i % EmojiCatalog.gridColumns)
            keys.append(Key(action: .text(emoji), label: emoji,
                            unitFrame: CGRect(x: col, y: row, width: 1, height: 1)))
        }

        keys.append(hideKey(row: 4))
        keys.append(Key(action: .layer(.letters), label: "ABC",
                        unitFrame: CGRect(x: 0.9, y: 4, width: 1.1, height: 1)))
        keys.append(Key(action: .emojiPageDelta(-1), label: "‹",
                        unitFrame: CGRect(x: 2.0, y: 4, width: 0.8, height: 1)))
        keys.append(Key(action: .space, label: "espacio",
                        unitFrame: CGRect(x: 2.8, y: 4, width: 4.0, height: 1)))
        keys.append(Key(action: .emojiPageDelta(1), label: "›",
                        unitFrame: CGRect(x: 6.8, y: 4, width: 0.8, height: 1)))
        keys.append(Key(action: .backspace, label: "⌫",
                        unitFrame: CGRect(x: 7.6, y: 4, width: 1.2, height: 1)))
        keys.append(Key(action: .ret, label: "⏎",
                        unitFrame: CGRect(x: 8.8, y: 4, width: 1.2, height: 1)))

        return KeyboardLayout(keys: keys)
    }
}
