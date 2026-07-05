import Foundation

/// Plan A — transform-anywhere. A text transformation the user can apply to
/// the selection (or whole field) of the focused app. v1 ships the two
/// in-place actions; the rest of the plan's actions land on the board's
/// preview mode later.
enum TransformAction: String, CaseIterable {
    case fix
    case translate

    var title: String {
        switch self {
        case .fix: return "Corregir"
        case .translate: return "Traducir ES ↔ EN"
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
