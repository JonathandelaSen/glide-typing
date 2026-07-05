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

    /// System prompt. The output contract — only the transformed text, no
    /// quotes, no commentary — is what `TransformCleaner.clean` assumes.
    var instructions: String {
        switch self {
        case .fix:
            return "Corrige la ortografía y la gramática del texto sin cambiar "
                + "su significado, su tono ni su idioma. Responde ÚNICAMENTE con "
                + "el texto corregido, sin comillas ni explicaciones."
        case .translate:
            return "Traduce el texto: si está en español, al inglés; en cualquier "
                + "otro caso, al español. Responde ÚNICAMENTE con la traducción, "
                + "sin comillas ni explicaciones."
        case .formal:
            return "Reescribe el texto con un tono formal y profesional, sin "
                + "cambiar su significado ni su idioma. Responde ÚNICAMENTE con "
                + "el texto reescrito, sin comillas ni explicaciones."
        case .casual:
            return "Reescribe el texto con un tono cercano y natural, sin "
                + "cambiar su significado ni su idioma. Responde ÚNICAMENTE con "
                + "el texto reescrito, sin comillas ni explicaciones."
        case .shorten:
            return "Reescribe el texto de forma más breve conservando toda la "
                + "información esencial, sin cambiar su idioma. Responde "
                + "ÚNICAMENTE con el texto acortado, sin comillas ni explicaciones."
        case .lengthen:
            return "Desarrolla el texto con algo más de detalle manteniendo su "
                + "tono e idioma. Responde ÚNICAMENTE con el texto ampliado, "
                + "sin comillas ni explicaciones."
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
    static let instructions = "Eres un asistente de redacción dentro de un teclado. "
        + "El usuario te da una instrucción y, cuando existe, el contexto del campo "
        + "donde se insertará el resultado. Escribe el texto pedido, listo para "
        + "insertarse tal cual, en el idioma que pida el contexto o la instrucción. "
        + "Responde ÚNICAMENTE con el texto generado, sin comillas ni explicaciones."

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
        for prefix in ["resultado:", "respuesta:", "texto:", "traducción:", "traduccion:"] {
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
        let refusals = ["no puedo", "lo siento", "no hay texto", "no hay suficiente"]
        guard !s.isEmpty,
              !refusals.contains(where: { s.lowercased().hasPrefix($0) }) else { return nil }
        return s
    }
}
