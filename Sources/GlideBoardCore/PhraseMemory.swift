import Foundation

/// Personal next-word memory: n-gram counts (1–3 context words → next word)
/// learned from text the user actually sends. Deterministic, instant and
/// fully local — it answers BEFORE the LLM, but only when its own evidence
/// is strong; otherwise it stays silent and the LLM pipeline takes over.
final class PhraseMemory {

    /// A confident suggestion and the evidence behind it (shown in consoles).
    struct Hit {
        let word: String
        /// How many context words matched (3 = strongest).
        let order: Int
        let count: Double
        /// Fraction of all continuations of this context that were `word`.
        let share: Double
    }

    /// counts["crea una"] = ["rama": 7, "carpeta": 2] — keys are the last
    /// 1...maxOrder words of the context, values are next-word weights.
    private(set) var counts: [String: [String: Double]] = [:]
    static let maxOrder = 3

    /// Evidence thresholds: dominant share, and a minimum weight that is
    /// stricter for single-word contexts (they are noisier).
    static let minShare = 0.6
    private static func minCount(order: Int) -> Double { order == 1 ? 3 : 2 }

    private let url: URL
    private var saveScheduled = false

    private struct Stored: Codable {
        var savedAt: Date
        var counts: [String: [String: Double]]
    }

    /// `directory` overrides the Application Support location (tests use a
    /// temporary folder so runs never touch — or depend on — real user data).
    init(language: Language, directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("phrase_memory_\(language.rawValue).json")

        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            counts = stored.counts
            // Recency decay: halve roughly every 8 months of shelf life, so
            // last year's phrasing doesn't outvote the current project's.
            let weeks = Date().timeIntervalSince(stored.savedAt) / (7 * 24 * 3600)
            if weeks > 1 {
                let factor = pow(0.98, weeks)
                for key in counts.keys {
                    counts[key] = counts[key]?.mapValues { $0 * factor }
                }
            }
        }
    }

    // MARK: - Tokenization

    /// Lowercased words with edge punctuation stripped — the shared key
    /// format for learning and lookup.
    static func tokens(_ text: String) -> [String] {
        let punctuation = CharacterSet(charactersIn: ".,;:!?¿¡\"'“”«»()[]{}<>…—")
        return text.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap {
            let word = String($0).trimmingCharacters(in: punctuation)
            return word.isEmpty ? nil : word
        }
    }

    // MARK: - Learning

    /// Learn every transition in a finished text (called when the composer
    /// is sent — final words only, never mid-edit noise).
    func learn(text: String) {
        let words = Self.tokens(text)
        guard words.count >= 2 else { return }
        for i in 1..<words.count {
            guard words[i].first?.isLetter == true else { continue }
            for k in 1...Self.maxOrder where i - k >= 0 {
                let key = words[(i - k)..<i].joined(separator: " ")
                counts[key, default: [:]][words[i], default: 0] += 1
            }
        }
        scheduleSave()
    }

    // MARK: - Suggesting

    /// Stupid backoff over the context's last 3 → 2 → 1 words. Returns a hit
    /// only when the top continuation dominates with enough evidence.
    func suggest(context: String) -> Hit? {
        let ctx = Self.tokens(context)
        guard !ctx.isEmpty else { return nil }
        for order in stride(from: min(Self.maxOrder, ctx.count), through: 1, by: -1) {
            let key = ctx.suffix(order).joined(separator: " ")
            guard let continuations = counts[key], !continuations.isEmpty else { continue }
            let total = continuations.values.reduce(0, +)
            guard let (word, weight) = continuations.max(by: { $0.value < $1.value }) else { continue }
            let share = weight / total
            if weight >= Self.minCount(order: order), share >= Self.minShare,
               word != ctx.last {
                return Hit(word: word, order: order, count: weight, share: share)
            }
        }
        return nil
    }

    // MARK: - Introspection (memory visualizer)

    var contextCount: Int { counts.count }
    var sampleCount: Int { Int(counts.values.reduce(0) { $0 + $1.values.reduce(0, +) }) }

    /// Strongest memories first: contexts whose top continuation would
    /// actually fire, then the rest by weight.
    func topEntries(limit: Int = 120) -> [(context: String, words: [(word: String, weight: Double)], fires: Bool)] {
        counts.map { key, continuations in
            let sorted = continuations.sorted { $0.value > $1.value }
                .map { (word: $0.key, weight: $0.value) }
            let total = continuations.values.reduce(0, +)
            let order = key.split(separator: " ").count
            let fires = sorted.first.map {
                $0.weight >= Self.minCount(order: order) && $0.weight / total >= Self.minShare
            } ?? false
            return (context: key, words: sorted, fires: fires)
        }
        .sorted {
            if $0.fires != $1.fires { return $0.fires }
            return ($0.words.first?.weight ?? 0) > ($1.words.first?.weight ?? 0)
        }
        .prefix(limit).map { $0 }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            // Prune what decay has made irrelevant before writing.
            for (key, words) in self.counts {
                let kept = words.filter { $0.value >= 0.3 }
                if kept.isEmpty { self.counts.removeValue(forKey: key) }
                else if kept.count != words.count { self.counts[key] = kept }
            }
            if let data = try? JSONEncoder().encode(Stored(savedAt: Date(), counts: self.counts)) {
                try? data.write(to: self.url)
            }
        }
    }
}
