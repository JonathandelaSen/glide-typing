import Foundation
@testable import GlideBoardCore

@MainActor
func gestureRankingChecks() async {
    let c = Checks.shared
    c.begin("GestureRanker")

    func candidate(_ word: String, cost: Double, rank: Int = 100,
                   language: Language = .spanish) -> GestureCandidate {
        GestureCandidate(word: word, gestureCost: cost, rank: rank, language: language)
    }

    await c.test("active-language candidate wins on equal gesture cost") {
        let out = GestureRanker.rank([candidate("word", cost: 1, language: .english),
                                      candidate("verde", cost: 1, language: .spanish)],
                                     activeLanguage: .spanish)
        try expectEqual(out.first?.word, "verde")
    }

    await c.test("foreign candidates need a clear margin to stay eligible") {
        // 0.1 better than the best active candidate: not enough (margin 0.32).
        let out = GestureRanker.rank([candidate("hola", cost: 1.0, language: .spanish),
                                      candidate("hole", cost: 0.9, language: .english)],
                                     activeLanguage: .spanish)
        try expectEqual(out.map(\.word), ["hola"])
    }

    await c.test("a clearly better foreign candidate survives and can win") {
        let out = GestureRanker.rank([candidate("hola", cost: 1.0, language: .spanish),
                                      candidate("hello", cost: 0.4, language: .english)],
                                     activeLanguage: .spanish)
        try expectEqual(out.first?.word, "hello")
    }

    await c.test("frequency rank breaks ties between equal gestures") {
        let out = GestureRanker.rank([candidate("raro", cost: 1, rank: 20000),
                                      candidate("casa", cost: 1, rank: 50)],
                                     activeLanguage: .spanish)
        try expectEqual(out.first?.word, "casa")
    }

    await c.test("personal score can rescue a slightly worse candidate") {
        let out = GestureRanker.rank([candidate("cosa", cost: 1.0),
                                      candidate("casa", cost: 1.1)],
                                     activeLanguage: .spanish,
                                     personalScore: { $0 == "casa" ? 1 : 0 })
        try expectEqual(out.first?.word, "casa")
    }

    await c.test("PersonalWordModel learns, scores and persists") {
        let dir = temporaryDirectory()
        let model = PersonalWordModel(directory: dir)
        try expectEqual(model.score("teclado"), 0)
        model.learn("Teclado")
        try expectTrue(model.score("teclado") > 0, "learning must raise the score")
        try expectTrue(model.score("teclado") <= 1, "scores are capped at 1")
        let reloaded = PersonalWordModel(directory: dir)
        try expectTrue(reloaded.score("teclado") > 0, "score must survive a relaunch")
    }
}
