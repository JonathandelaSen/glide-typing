import Foundation
@testable import GlideBoardCore

@MainActor
func bigramModelChecks() async {
    let c = Checks.shared
    c.begin("BigramModel")

    await c.test("loads the corpus bigrams from Resources") {
        // Use whatever the corpus actually starts with, so the check does not
        // depend on any particular word being present.
        let raw = try String(contentsOfFile: "Resources/es_bigrams.txt", encoding: .utf8)
        let firstLine = try unwrap(raw.split(separator: "\n").first.map(String.init))
        let previous = String(firstLine.split(separator: " ")[0])
        let model = BigramModel(language: .spanish, directory: temporaryDirectory())
        try expectFalse(model.predict(after: previous).isEmpty,
                        "no predictions after corpus word '\(previous)'")
    }

    await c.test("learned bigrams dominate the corpus") {
        let model = BigramModel(language: .spanish, directory: temporaryDirectory())
        model.learn(previous: "Hola", word: "Zebra")
        try expectEqual(model.predict(after: "hola").first, "zebra",
                        "one learned observation must outrank the whole corpus")
    }

    await c.test("learning ignores words that do not start with a letter") {
        let model = BigramModel(language: .spanish, directory: temporaryDirectory())
        model.learn(previous: "hola", word: "123")
        try expectFalse(model.predict(after: "hola").contains("123"))
    }

    await c.test("score is 0 without context and ranks predictions") {
        let model = BigramModel(language: .spanish, directory: temporaryDirectory())
        try expectEqual(model.score(previous: nil, word: "hola"), 0)
        model.learn(previous: "buenos", word: "días")
        try expectTrue(model.score(previous: "buenos", word: "días") > 0)
        try expectEqual(model.score(previous: "buenos", word: "zzzzz"), 0)
    }
}
