import Foundation

/// Next-word prediction: corpus bigrams seeded from a resource file, plus
/// bigrams learned from what the user actually writes (persisted to disk).
final class BigramModel {
    private var corpus: [String: [(word: String, count: Double)]] = [:]
    private var learned: [String: [String: Double]] = [:]
    private let learnedURL: URL
    private var saveScheduled = false

    init(language: Language) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        learnedURL = support.appendingPathComponent("learned_\(language.rawValue).json")

        if let url = Self.locate("\(language.wordFile.prefix(2))_bigrams"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let count = Double(parts[2]) else { continue }
                corpus[String(parts[0]), default: []].append((String(parts[1]), count))
            }
            for key in corpus.keys {
                corpus[key]?.sort { $0.count > $1.count }
            }
        }

        if let data = try? Data(contentsOf: learnedURL),
           let dict = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            learned = dict
        }
    }

    func predict(after word: String, limit: Int = 4) -> [String] {
        let prev = word.lowercased()
        var scores: [String: Double] = [:]
        // Learned bigrams dominate: the user's own phrasing wins over the corpus.
        if let mine = learned[prev] {
            for (w, c) in mine { scores[w, default: 0] += c * 1000 }
        }
        if let common = corpus[prev] {
            for (i, item) in common.prefix(20).enumerated() {
                scores[item.word, default: 0] += Double(20 - i)
            }
        }
        return scores.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    func score(previous: String?, word: String) -> Double {
        guard let previous else { return 0 }
        let predictions = predict(after: previous, limit: 20)
        guard let index = predictions.firstIndex(of: word.lowercased()) else { return 0 }
        return 1 - Double(index) / Double(max(1, predictions.count))
    }

    func learn(previous: String?, word: String) {
        guard let prev = previous?.lowercased(), !prev.isEmpty else { return }
        let w = word.lowercased()
        guard w.first?.isLetter == true else { return }
        learned[prev, default: [:]][w, default: 0] += 1
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let data = try? JSONEncoder().encode(self.learned) {
                try? data.write(to: self.learnedURL)
            }
        }
    }

    private static func locate(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("\(name).txt"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/\(name).txt"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
