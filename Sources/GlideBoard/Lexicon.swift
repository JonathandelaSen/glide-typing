import Foundation

/// Word list for gesture decoding and autocompletion. Loads one or more
/// language files (bilingual decoding) plus user-learned words.
final class Lexicon {
    struct Entry {
        let word: String
        /// Letters with accents stripped, consecutive duplicates removed —
        /// the sequence of distinct keys a glide must pass through.
        let keySequence: [Character]
        /// Accent-stripped word (not deduped) — for prefix autocompletion.
        let normalized: String
        let rank: Int
        let language: Language
    }

    /// Rank given to user-learned words: high priority without beating
    /// the language's most frequent words.
    static let userWordRank = 50

    private(set) var entries: [Entry] = []
    /// Entries indexed by (firstKey, lastKey) for fast candidate pruning.
    private(set) var byEnds: [String: [Entry]] = [:]
    /// Entries indexed by first key — for partial (in-progress) decoding.
    private(set) var byFirst: [Character: [Entry]] = [:]
    private var known = Set<String>()

    init(languages: [Language]) {
        for language in languages {
            loadFile(language.wordFile)
        }
    }

    func contains(_ word: String) -> Bool {
        known.contains(word.lowercased())
    }

    /// Add a user word with high priority — it becomes glidable and completable.
    @discardableResult
    func learn(_ word: String) -> Bool {
        let w = word.lowercased()
        guard w.count >= 3, !known.contains(w), w.allSatisfy({ $0.isLetter }) else { return false }
        let keys = Lexicon.keySequence(for: w)
        guard keys.count >= 2 else { return false }
        let entry = Entry(word: w, keySequence: keys,
                          normalized: String(w.map(Lexicon.baseKey)),
                          rank: Lexicon.userWordRank, language: .spanish)
        entries.insert(entry, at: min(Lexicon.userWordRank, entries.count))
        byEnds["\(keys.first!)\(keys.last!)", default: []].append(entry)
        byFirst[keys.first!, default: []].append(entry)
        known.insert(w)
        return true
    }

    /// Best words starting with the given (possibly accentless) prefix,
    /// ranked across all loaded languages and user words. When prefix matches
    /// are scarce, falls back to abbreviation matching: the typed letters as
    /// an in-order subsequence ("tcld" → "teclado").
    func completions(prefix: String, limit: Int = 4) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let norm = String(prefix.lowercased().map(Lexicon.baseKey))
        var matches: [Entry] = []
        for entry in entries where entry.normalized.hasPrefix(norm) && entry.word.count > prefix.count {
            matches.append(entry)
            if matches.count >= 400 { break }
        }
        var out = matches.sorted { $0.rank < $1.rank }.prefix(limit).map { $0.word }
        if out.count < limit && norm.count >= 3 {
            var abbreviations: [Entry] = []
            for entry in entries
            where entry.normalized.first == norm.first
                && entry.word.count > prefix.count
                && !entry.normalized.hasPrefix(norm)
                && Lexicon.isSubsequence(norm, of: entry.normalized) {
                abbreviations.append(entry)
                if abbreviations.count >= 200 { break }
            }
            for entry in abbreviations.sorted(by: { $0.rank < $1.rank }) {
                if !out.contains(entry.word) {
                    out.append(entry.word)
                    if out.count == limit { break }
                }
            }
        }
        return out
    }

    static func isSubsequence(_ small: String, of big: String) -> Bool {
        var it = small.makeIterator()
        var target = it.next()
        for ch in big {
            if ch == target {
                target = it.next()
                if target == nil { return true }
            }
        }
        return target == nil
    }

    private func loadFile(_ name: String) {
        guard let url = Lexicon.locateWordFile(name),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("GlideBoard: could not load word list '\(name)'")
            return
        }
        var rank = 0
        for line in raw.split(separator: "\n") {
            let word = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard word.count >= 2, !known.contains(word) else { continue }
            known.insert(word)
            let keys = Lexicon.keySequence(for: word)
            guard keys.count >= 2 else { rank += 1; continue } // single-key words are tapped, not glided
            let entry = Entry(word: word, keySequence: keys,
                              normalized: String(word.map(Lexicon.baseKey)), rank: rank,
                              language: name.hasPrefix("en") ? .english : .spanish)
            entries.append(entry)
            byEnds["\(keys.first!)\(keys.last!)", default: []].append(entry)
            byFirst[keys.first!, default: []].append(entry)
            rank += 1
        }
    }

    /// Map accented characters to their key, drop consecutive duplicate keys.
    static func keySequence(for word: String) -> [Character] {
        var out: [Character] = []
        for ch in word {
            let key = baseKey(ch)
            if out.last != key { out.append(key) }
        }
        return out
    }

    static func baseKey(_ ch: Character) -> Character {
        switch ch {
        case "á", "à", "ä", "â": return "a"
        case "é", "è", "ë", "ê": return "e"
        case "í", "ì", "ï", "î": return "i"
        case "ó", "ò", "ö", "ô": return "o"
        case "ú", "ù", "ü", "û": return "u"
        default: return ch
        }
    }

    private static func locateWordFile(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("\(name).txt"))
        }
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("Resources/\(name).txt"))
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/\(name).txt"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Persists user-learned words across launches.
final class UserDictionary {
    private let url: URL
    private(set) var words: [String] = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("user_words.txt")
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            words = raw.split(separator: "\n").map(String.init)
        }
    }

    func add(_ word: String) {
        guard !words.contains(word) else { return }
        words.append(word)
        save()
    }

    func replaceAll(_ newWords: [String]) {
        var seen = Set<String>()
        words = newWords
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        save()
    }

    private func save() {
        try? words.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
