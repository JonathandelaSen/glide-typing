import AppKit

enum KeyAction: Equatable {
    case char(Character)
    case space
    case backspace
    case ret
    case language
    case hide
}

struct Key {
    let action: KeyAction
    let label: String
    /// Frame in unit-grid coordinates (1 unit = one standard key cell).
    let unitFrame: CGRect
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

struct KeyboardLayout {
    let keys: [Key]
    let unitColumns: CGFloat = 10
    let unitRows: CGFloat = 4

    static func build(for language: Language) -> KeyboardLayout {
        var keys: [Key] = []

        func row(_ letters: String, row: CGFloat, offset: CGFloat) {
            for (i, ch) in letters.enumerated() {
                keys.append(Key(action: .char(ch),
                                label: String(ch),
                                unitFrame: CGRect(x: offset + CGFloat(i), y: row, width: 1, height: 1)))
            }
        }

        row("qwertyuiop", row: 0, offset: 0)
        switch language {
        case .english:
            row("asdfghjkl", row: 1, offset: 0.5)
        case .spanish:
            row("asdfghjklñ", row: 1, offset: 0)
        }
        row("zxcvbnm", row: 2, offset: 1.0)
        keys.append(Key(action: .backspace, label: "⌫",
                        unitFrame: CGRect(x: 8.25, y: 2, width: 1.75, height: 1)))

        keys.append(Key(action: .hide, label: "✕",
                        unitFrame: CGRect(x: 0, y: 3, width: 1.1, height: 1)))
        keys.append(Key(action: .language, label: language.rawValue,
                        unitFrame: CGRect(x: 1.1, y: 3, width: 1.1, height: 1)))
        keys.append(Key(action: .char(","), label: ",",
                        unitFrame: CGRect(x: 2.2, y: 3, width: 0.9, height: 1)))
        keys.append(Key(action: .space, label: "espacio",
                        unitFrame: CGRect(x: 3.1, y: 3, width: 4.0, height: 1)))
        keys.append(Key(action: .char("."), label: ".",
                        unitFrame: CGRect(x: 7.1, y: 3, width: 0.9, height: 1)))
        keys.append(Key(action: .ret, label: "⏎",
                        unitFrame: CGRect(x: 8.0, y: 3, width: 2.0, height: 1)))

        return KeyboardLayout(keys: keys)
    }
}
