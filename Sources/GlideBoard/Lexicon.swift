import Foundation

/// A word list ordered by frequency (rank 0 = most frequent).
final class Lexicon {
    struct Entry {
        let word: String
        /// Letters with accents stripped, consecutive duplicates removed —
        /// the sequence of distinct keys a glide must pass through.
        let keySequence: [Character]
        let rank: Int
    }

    private(set) var entries: [Entry] = []
    /// Entries indexed by (firstKey, lastKey) for fast candidate pruning.
    private(set) var byEnds: [String: [Entry]] = [:]
    /// Entries indexed by first key — for partial (in-progress) decoding.
    private(set) var byFirst: [Character: [Entry]] = [:]

    init(language: Language) {
        guard let url = Lexicon.locateWordFile(language.wordFile),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("GlideBoard: could not load word list for \(language.rawValue)")
            return
        }
        var seen = Set<String>()
        var rank = 0
        for line in raw.split(separator: "\n") {
            let word = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard word.count >= 2, !seen.contains(word) else { continue }
            seen.insert(word)
            let keys = Lexicon.keySequence(for: word)
            guard keys.count >= 2 else { rank += 1; continue } // single-key words are tapped, not glided
            let entry = Entry(word: word, keySequence: keys, rank: rank)
            entries.append(entry)
            let bucket = "\(keys.first!)\(keys.last!)"
            byEnds[bucket, default: []].append(entry)
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
