import Foundation

struct GestureCandidate {
    let word: String
    let gestureCost: Double
    let rank: Int
    let language: Language
}

enum GestureRanker {
    static func rank(_ candidates: [GestureCandidate],
                     activeLanguage: Language,
                     contextScore: (String) -> Double = { _ in 0 },
                     personalScore: (String) -> Double = { _ in 0 }) -> [GestureCandidate] {
        let bestActiveCost = candidates
            .filter { $0.language == activeLanguage }
            .map(\.gestureCost)
            .min()
        let eligible = candidates.filter { candidate in
            guard candidate.language != activeLanguage, let bestActiveCost else { return true }
            return candidate.gestureCost + 0.32 < bestActiveCost
        }
        return eligible.sorted {
            cost($0, activeLanguage: activeLanguage,
                 contextScore: contextScore, personalScore: personalScore)
            < cost($1, activeLanguage: activeLanguage,
                   contextScore: contextScore, personalScore: personalScore)
        }
    }

    private static func cost(_ candidate: GestureCandidate,
                             activeLanguage: Language,
                             contextScore: (String) -> Double,
                             personalScore: (String) -> Double) -> Double {
        let frequency = 0.08 * log10(Double(candidate.rank + 10))
        let languageBonus = candidate.language == activeLanguage ? 0.18 : 0
        return candidate.gestureCost + frequency - languageBonus
            - 0.34 * contextScore(candidate.word) - 0.28 * personalScore(candidate.word)
    }
}

final class PersonalWordModel {
    private var counts: [String: Double] = [:]
    private let url: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("personal_words.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Double].self, from: data) {
            counts = stored
        }
    }

    func score(_ word: String) -> Double {
        min(1, log10(counts[word.lowercased(), default: 0] + 1) / 2)
    }

    func learn(_ word: String, weight: Double = 1) {
        counts[word.lowercased(), default: 0] += weight
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: url) }
    }
}
