import Foundation

/// Plan A — transform-anywhere. A text transformation the user can apply to
/// the selection (or whole field) of the focused app, or to the board's
/// draft. Predictable actions write back in place; the rest preview in the
/// board so they can be iterated before injecting.
enum TransformAction: String, CaseIterable {
    case fix
    case translate
    case formal
    case casual
    case shorten
    case lengthen

    var title: String {
        switch self {
        case .fix: return "Corregir"
        case .translate: return "Traducir ES ↔ EN"
        case .formal: return "Tono formal"
        case .casual: return "Tono casual"
        case .shorten: return "Acortar"
        case .lengthen: return "Alargar"
        }
    }

    /// Predictable transformations replace the text directly; the rest go to
    /// the board's composer for review first.
    var deliversInPlace: Bool {
        switch self {
        case .fix, .translate: return true
        case .formal, .casual, .shorten, .lengthen: return false
        }
    }

    /// System prompt. Written in English so the instruction language never
    /// biases the output; every action that isn't `translate` ends with an
    /// explicit "same language as the input" rule, which small models honour
    /// far better than a buried clause. The output contract — only the
    /// transformed text, no quotes — is what `TransformCleaner.clean` assumes.
    var instructions: String {
        let sameLanguage = " Always write your reply in the SAME language as the "
            + "input text; never translate it."
        switch self {
        case .fix:
            return "Fix the spelling and grammar of the text without changing its "
                + "meaning or tone. Reply with the corrected text ONLY, no quotes "
                + "or explanations." + sameLanguage
        case .translate:
            return "Translate the text: if it is in Spanish, translate it to "
                + "English; otherwise, translate it to Spanish. Reply with the "
                + "translation ONLY, no quotes or explanations."
        case .formal:
            return "Rewrite the text in a formal, professional tone without "
                + "changing its meaning. Reply with the rewritten text ONLY, no "
                + "quotes or explanations." + sameLanguage
        case .casual:
            return "Rewrite the text in a warm, natural tone without changing its "
                + "meaning. Reply with the rewritten text ONLY, no quotes or "
                + "explanations." + sameLanguage
        case .shorten:
            return "Rewrite the text more concisely while keeping all the "
                + "essential information. Reply with the shortened text ONLY, no "
                + "quotes or explanations." + sameLanguage
        case .lengthen:
            return "Expand the text with a bit more detail while keeping its "
                + "tone. Reply with the expanded text ONLY, no quotes or "
                + "explanations." + sameLanguage
        }
    }

    /// Single plain-text prompt, for providers without a system/user split.
    func prompt(for text: String) -> String {
        instructions + "\n\nTexto:\n" + text + "\n\nResultado:"
    }

    /// Transforms are roughly input-sized; leave room for expansion.
    func maxTokens(for text: String) -> Int {
        max(80, text.count / 2)
    }
}

/// Plan B — prompt-anywhere: generate new text from a free instruction, using
/// the AX context of wherever it will land. Shares provider and menu with the
/// transform actions.
enum PromptAnywhere {
    static let instructions = "You are a writing assistant inside a keyboard. "
        + "The user gives you an instruction and, when available, the context of "
        + "the field where the result will be inserted. Write the requested text, "
        + "ready to be inserted as-is. Write it in the language of the surrounding "
        + "text or draft; only switch languages if the instruction explicitly asks "
        + "for it. Reply with the generated text ONLY, no quotes or explanations."

    /// The exact plain-text body sent to the model — also what lands in the
    /// debug console, so the user can audit every piece of context read.
    static func prompt(instruction: String, draft: String?,
                       context: String?, target: String?) -> String {
        var parts: [String] = []
        if let target, !target.isEmpty { parts.append("Destino: \(target)") }
        if let context, !context.isEmpty { parts.append("Contexto visible:\n\(context)") }
        if let draft, !draft.isEmpty { parts.append("Borrador actual:\n\(draft)") }
        parts.append("Instrucción: \(instruction)")
        parts.append("Resultado:")
        return parts.joined(separator: "\n\n")
    }

    static func maxTokens(for instruction: String) -> Int { 400 }
}

enum TransformCleaner {
    /// Normalize a model response into insertable text, or nil when the
    /// model answered with meta-talk instead of a transformation.
    static func clean(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["resultado:", "respuesta:", "texto:", "traducción:", "traduccion:",
                       "result:", "reply:", "text:", "translation:", "output:"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Strip one layer of wrapping quotes, a habit models can't shake.
        if s.count >= 2, let first = s.first, let last = s.last,
           "\"“«'".contains(first), "\"”»'".contains(last) {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let refusals = ["no puedo", "lo siento", "no hay texto", "no hay suficiente",
                        "i can't", "i cannot", "i'm sorry", "i am sorry", "there is no"]
        guard !s.isEmpty,
              !refusals.contains(where: { s.lowercased().hasPrefix($0) }) else { return nil }
        return s
    }
}
