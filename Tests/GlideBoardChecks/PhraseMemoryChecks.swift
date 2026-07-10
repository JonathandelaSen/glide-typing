import Foundation
@testable import GlideBoardCore

@MainActor
func phraseMemoryChecks() async {
    let c = Checks.shared
    c.begin("PhraseMemory")

    await c.test("tokens lowercase and strip edge punctuation") {
        try expectEqual(PhraseMemory.tokens("¡Hola, Mundo!"), ["hola", "mundo"])
        try expectEqual(PhraseMemory.tokens("«crea una rama»…"), ["crea", "una", "rama"])
        try expectEqual(PhraseMemory.tokens("   "), [])
    }

    await c.test("one observation is not enough evidence to suggest") {
        let memory = PhraseMemory(language: .spanish, directory: temporaryDirectory())
        memory.learn(text: "crea una rama")
        try expectNil(memory.suggest(context: "crea una"))
    }

    await c.test("a repeated multi-word context fires with its dominant word") {
        let memory = PhraseMemory(language: .spanish, directory: temporaryDirectory())
        memory.learn(text: "crea una rama")
        memory.learn(text: "crea una rama")
        let hit = try unwrap(memory.suggest(context: "por favor crea una"))
        try expectEqual(hit.word, "rama")
        try expectEqual(hit.order, 2)
        try expectTrue(hit.share >= PhraseMemory.minShare)
    }

    await c.test("single-word contexts demand stronger evidence") {
        let memory = PhraseMemory(language: .spanish, directory: temporaryDirectory())
        memory.learn(text: "vale genial")
        memory.learn(text: "vale genial")
        try expectNil(memory.suggest(context: "vale"),
                      "two observations must not fire an order-1 context")
        memory.learn(text: "vale genial")
        let hit = try unwrap(memory.suggest(context: "vale"))
        try expectEqual(hit.word, "genial")
    }

    await c.test("a split vote stays silent (no dominant continuation)") {
        let memory = PhraseMemory(language: .spanish, directory: temporaryDirectory())
        for _ in 0..<3 { memory.learn(text: "abre la puerta") }
        for _ in 0..<3 { memory.learn(text: "abre la ventana") }
        try expectNil(memory.suggest(context: "abre la"), "50/50 share must not fire")
    }

    await c.test("old memories decay on load until they stop firing") {
        let dir = temporaryDirectory()
        // Handcrafted store: strong enough to fire when fresh (weight 4),
        // saved one year ago — decay must push it below the threshold.
        let yearAgo = Date().addingTimeInterval(-365 * 24 * 3600)
            .timeIntervalSinceReferenceDate
        let json = """
        {"savedAt": \(yearAgo), "counts": {"crea una": {"rama": 4}}}
        """
        try json.write(to: dir.appendingPathComponent("phrase_memory_ES.json"),
                       atomically: true, encoding: .utf8)
        let memory = PhraseMemory(language: .spanish, directory: dir)
        try expectNil(memory.suggest(context: "crea una"),
                      "a year-old weight of 4 must have decayed below the threshold")

        // Control: the same store saved today does fire.
        let freshDir = temporaryDirectory()
        let now = Date().timeIntervalSinceReferenceDate
        try """
        {"savedAt": \(now), "counts": {"crea una": {"rama": 4}}}
        """.write(to: freshDir.appendingPathComponent("phrase_memory_ES.json"),
                  atomically: true, encoding: .utf8)
        let fresh = PhraseMemory(language: .spanish, directory: freshDir)
        try expectEqual(fresh.suggest(context: "crea una")?.word, "rama")
    }
}
