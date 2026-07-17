import Foundation

/// Deterministic filtering and ranking for the command palette. Pure logic:
/// same entries + query + recents always produce the same order.
enum PaletteSearch {
    /// Case- and diacritic-insensitive comparison key ("Atención" → "atencion").
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "es_ES"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lower is better. `nil` means the entry does not match the query.
    static func matchRank(query: String, title: String,
                          aliases: [String], keywords: [String]) -> Int?
    {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        let t = normalize(title)
        if t.hasPrefix(q) { return 0 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
        if t.contains(q) { return 2 }
        let a = aliases.map(normalize)
        if a.contains(where: { $0.hasPrefix(q) }) { return 3 }
        if a.contains(where: { $0.contains(q) }) { return 4 }
        if keywords.map(normalize).contains(where: { $0.hasPrefix(q) }) { return 5 }
        // Multi-word query: every token must prefix some word of some field.
        let tokens = q.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return nil }
        let words = ([t] + a + keywords.map(normalize))
            .flatMap { $0.split(separator: " ").map(String.init) }
        let allMatch = tokens.allSatisfy { token in
            words.contains { $0.hasPrefix(token) }
        }
        return allMatch ? 6 : nil
    }

    /// Orders the catalog for display: matching entries only, available
    /// before unavailable, better matches first, then recency, then stable
    /// catalog order.
    static func results(query: String,
                        entries: [NumaActionCatalog.ResolvedAction],
                        recents: [String]) -> [NumaActionCatalog.ResolvedAction]
    {
        let scored: [(entry: NumaActionCatalog.ResolvedAction, sortKey: [Int])] =
            entries.enumerated().compactMap { index, entry in
                guard let rank = matchRank(query: query,
                                           title: entry.descriptor.title,
                                           aliases: entry.descriptor.aliases,
                                           keywords: entry.descriptor.keywords)
                else { return nil }
                let recency = recents.firstIndex(of: entry.descriptor.id.rawValue)
                    ?? Int.max
                let available = entry.availability.isAvailable ? 0 : 1
                return (entry, [available, rank, recency, index])
            }
        return scored
            .sorted { lhs, rhs in
                for (l, r) in zip(lhs.sortKey, rhs.sortKey) where l != r { return l < r }
                return false
            }
            .map(\.entry)
    }
}
