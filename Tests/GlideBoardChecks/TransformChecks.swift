import Foundation
@testable import GlideBoardCore

@MainActor
func transformChecks() async {
    let c = Checks.shared
    c.begin("Transform / prompt-anywhere")

    await c.test("only predictable actions deliver in place") {
        try expectTrue(TransformAction.fix.deliversInPlace)
        try expectTrue(TransformAction.translate.deliversInPlace)
        for action in [TransformAction.formal, .casual, .shorten, .lengthen] {
            try expectFalse(action.deliversInPlace, "\(action) must preview first")
        }
    }

    await c.test("every action except translate pins the reply language") {
        for action in TransformAction.allCases where action != .translate {
            try expectTrue(action.instructions.contains("SAME language"),
                           "\(action) is missing the same-language rule")
        }
        try expectFalse(TransformAction.translate.instructions.contains("SAME language"))
    }

    await c.test("prompt embeds the instructions and the text") {
        let prompt = TransformAction.fix.prompt(for: "ola ke ase")
        try expectTrue(prompt.contains(TransformAction.fix.instructions))
        try expectTrue(prompt.contains("ola ke ase"))
        try expectTrue(prompt.hasSuffix("Resultado:"))
    }

    await c.test("maxTokens scales with the input but never starves") {
        try expectEqual(TransformAction.fix.maxTokens(for: "hola"), 80)
        try expectEqual(TransformAction.fix.maxTokens(for: String(repeating: "a", count: 400)), 200)
    }

    await c.test("cleaner strips label prefixes and wrapping quotes") {
        try expectEqual(TransformCleaner.clean("Resultado: Hola"), "Hola")
        try expectEqual(TransformCleaner.clean("«Hola mundo»"), "Hola mundo")
        // Prefixes are stripped before quotes, so this order composes…
        try expectEqual(TransformCleaner.clean("Traducción: «bien»"), "bien")
        // …while a label hidden inside quotes survives (current behavior).
        try expectEqual(TransformCleaner.clean("\"Traducción: bien\""), "Traducción: bien")
        try expectEqual(TransformCleaner.clean("  texto normal  "), "texto normal")
    }

    await c.test("cleaner turns refusals and empty replies into nil") {
        try expectNil(TransformCleaner.clean("No puedo ayudar con eso"))
        try expectNil(TransformCleaner.clean("I'm sorry, but…"))
        try expectNil(TransformCleaner.clean("   "))
        try expectNil(TransformCleaner.clean("\"\""))
    }

    await c.test("prompt-anywhere assembles only the parts it has") {
        let full = PromptAnywhere.prompt(instruction: "saluda", draft: "borra",
                                         context: "hilo", target: "Slack — #dev")
        try expectTrue(full.contains("Destino: Slack — #dev"))
        try expectTrue(full.contains("Contexto visible:\nhilo"))
        try expectTrue(full.contains("Borrador actual:\nborra"))
        try expectTrue(full.contains("Instrucción: saluda"))
        try expectTrue(full.hasSuffix("Resultado:"))

        let bare = PromptAnywhere.prompt(instruction: "saluda", draft: nil,
                                         context: nil, target: nil)
        try expectFalse(bare.contains("Destino:"))
        try expectFalse(bare.contains("Contexto"))
        try expectFalse(bare.contains("Borrador"))
    }
}
