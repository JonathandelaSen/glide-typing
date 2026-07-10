import Foundation

/// Curated emoji palette for the emoji layer, plus a persistent "recents"
/// category (index 0) fed by actual use.
enum EmojiCatalog {
    struct Category {
        let icon: String
        let name: String
        let emojis: [String]
    }

    static let gridColumns = 10
    static let gridRows = 3
    static var perPage: Int { gridColumns * gridRows }

    private static let recentsKey = "GlideBoard.emojiRecents"
    private static let recentsLimit = 30

    /// Splitting through Character keeps multi-scalar emoji (variation
    /// selectors, ZWJ sequences) intact.
    private static func split(_ s: String) -> [String] { s.map(String.init) }

    static let fixedCategories: [Category] = [
        Category(icon: "😀", name: "Caras", emojis: split(
            "😀😃😄😁😆😅😂🤣🙂😉😊😇🥰😍🤩😘😗😚😙😋😛😜🤪😝🤗🤭🤫🤔🫡😐😑😶🙄😏😌😴🤤😪😷🤒🤕🤢🤮🥴😵🤯🥳😎🤓🧐😕😟🙁😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬")),
        Category(icon: "👍", name: "Gestos", emojis: split(
            "👍👎👊✊🤛🤜👏🙌👐🤲🤝🙏✌️🤞🤟🤘🤙👌🤌🤏👈👉👆👇☝️✋🤚🖐🖖👋💪✍️💅🤳🫶🫰🫵🫱🫲🧠🫀🫁🦷🦴👀👁👅👄💋🩸")),
        Category(icon: "🐻", name: "Animales", emojis: split(
            "🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🙈🙉🙊🐔🐧🐦🐤🦆🦅🦉🦇🐺🐗🐴🦄🐝🐛🦋🐌🐞🐜🪲🐢🐍🦎🐙🦑🦐🦀🐡🐠🐟🐬🐳🐋🦈🐊🐅🐆🦓🦍🐘🦛🦏🐪🦒🦘🐃🐂🐄🐎🐖🐏🐑🐐")),
        Category(icon: "🍎", name: "Comida", emojis: split(
            "🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥬🥒🌶🌽🥕🧄🧅🥔🍠🥐🥯🍞🥖🥨🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖🌭🍔🍟🍕🥪🌮🌯🥗🍝🍜🍲🍣🍱🍚🍩🍪🎂🍰🧁🍫🍬🍭☕🍵🍺")),
        Category(icon: "⚽", name: "Actividades", emojis: split(
            "⚽🏀🏈⚾🥎🎾🏐🏉🥏🎱🏓🏸🏒🥅⛳🏹🎣🥊🥋🎽⛸🎿🛹🛼🏋️🤸⛹️🤺🤾🏌️🏇🧘🏄🏊🤽🚣🧗🚴🚵🎪🎭🎨🎬🎤🎧🎼🎹🥁🎷🎺🎸🪕🎻🎲♟🎯🎳🎮🎰🧩")),
        Category(icon: "✈️", name: "Viajes", emojis: split(
            "🚗🚕🚙🚌🚎🏎🚓🚑🚒🚐🛻🚚🚛🚜🛵🏍🚲🛴🚂🚄🚅🚈🚇🛫🛬✈️🚀🛸🚁⛵🚤🛳⚓🗺🗽🗼🏰🏯🏟🎡🎢🎠⛲🏖🏝🌋⛰🏔🗻🏕⛺🏠🏡🏢🌃🌆🌇🌉🌍🌎🌏")),
        Category(icon: "💡", name: "Objetos", emojis: split(
            "⌚📱💻⌨️🖥🖨🖱🕹💾💿📷📸📹🎥📞☎️📺📻🎙⏰🕰⌛⏳📡🔋🔌💡🔦🕯🗑💸💵💰💳💎⚖️🔧🔨🛠⛏🔩⚙️🔑🗝🚪🪑🛋🛏🧸🖼🛍🛒🎁🎈🎉🎊✉️📦📫📜📄📊📈📉📌📍✂️🖊✏️📝🔍🔒")),
        Category(icon: "❤️", name: "Símbolos", emojis: split(
            "❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💟✨⭐🌟💫💥🔥🌈☀️🌤⛅🌧⛈❄️💧🌊✅❌❓❗💯🔞⚠️🚫♻️💤🎵🎶➕➖➗✖️♾️💲™️©️®️👑🏆🥇🥈🥉🏅")),
    ]

    /// Tabs: recents first, then the fixed categories.
    static var categoryCount: Int { fixedCategories.count + 1 }

    static func icon(at index: Int) -> String {
        index == 0 ? "🕘" : fixedCategories[index - 1].icon
    }

    static func emojis(inCategory index: Int) -> [String] {
        index == 0 ? recents : fixedCategories[index - 1].emojis
    }

    /// Where to land when the emoji layer opens: recents if there are any.
    static var defaultCategory: Int { recents.isEmpty ? 1 : 0 }

    static func pageCount(category: Int) -> Int {
        let count = emojis(inCategory: category).count
        return max(1, Int(ceil(Double(count) / Double(perPage))))
    }

    static func page(category rawCategory: Int, page rawPage: Int) -> [String] {
        let category = min(max(0, rawCategory), categoryCount - 1)
        let all = emojis(inCategory: category)
        let page = min(max(0, rawPage), pageCount(category: category) - 1)
        let start = page * perPage
        guard start < all.count else { return [] }
        return Array(all[start..<min(start + perPage, all.count)])
    }

    // MARK: - Recents

    private static var cachedRecents: [String]?

    static var recents: [String] {
        if let cachedRecents { return cachedRecents }
        let stored = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        cachedRecents = stored
        return stored
    }

    static func recordRecent(_ emoji: String) {
        var list = recents
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        if list.count > recentsLimit { list = Array(list.prefix(recentsLimit)) }
        cachedRecents = list
        UserDefaults.standard.set(list, forKey: recentsKey)
    }
}
