import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One model query, fully described — for the live console.
struct ModelQuery {
    let kind: String
    let isPhrase: Bool
    let engine: String
    let ms: Int
    let source: String
    let context: String
    let raw: String
    let cleaned: String
    let date = Date()
    var isEmpty: Bool { cleaned == "(nada)" }
}

/// Live log of every model query.
final class QueryLog {
    static let shared = QueryLog()
    /// Set by the requester right before each call (context source label).
    var currentSource = "—"
    var sink: ((ModelQuery) -> Void)?
    var phraseAcceptedSink: (() -> Void)?
    /// Feeds the eval exporter: every query is a potential eval case.
    var evalSink: ((ModelQuery) -> Void)?

    func record(kind: String, isPhrase: Bool, engine: String, ms: Int,
                context: String, raw: String, cleaned: String) {
        let query = ModelQuery(kind: kind, isPhrase: isPhrase, engine: engine, ms: ms,
                               source: currentSource, context: context,
                               raw: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                               cleaned: cleaned)
        DispatchQueue.main.async {
            self.sink?(query)
            self.evalSink?(query)
        }
    }

    func recordPhraseAccepted() {
        DispatchQueue.main.async { self.phraseAcceptedSink?() }
    }
}

/// A source of short phrase completions ("ghost text") and word suggestions.
protocol CompletionProvider {
    func complete(context: String) async throws -> String?
    /// Candidate full words for the partial word being typed at the end of `context`.
    func suggestWords(context: String, partial: String) async throws -> [String]
}

enum CompletionCleaner {
    /// Keep the most relevant tail without erasing the final space/newline:
    /// that separator tells the model whether to continue or finish a word.
    static func contextForModel(_ raw: String, maxLength: Int = 450) -> String {
        guard raw.count > maxLength else { return raw }
        var tail = String(raw.suffix(maxLength))
        if let boundary = tail.firstIndex(where: { $0.isWhitespace }) {
            tail = String(tail[tail.index(after: boundary)...])
        }
        return tail
    }

    /// Normalize a model response into a short, insertable continuation.
    static func clean(_ raw: String, context: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = s.split(separator: "\n").first { s = String(firstLine) }
        s = s.replacingOccurrences(of: "<<<", with: " ")
            .replacingOccurrences(of: ">>>", with: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»<> "))
        let metaPrefixes = ["respuesta:", "continuación:", "continuacion:",
                            "no hay suficiente contexto", "no puedo", "texto:"]
        guard !metaPrefixes.contains(where: { s.lowercased().hasPrefix($0) }) else {
            return nil
        }

        // Models sometimes echo the prompt: drop the longest overlap between
        // the end of the context and the start of the response.
        let ctxWords = context.lowercased().split(separator: " ").map(String.init)
        var words = s.split(separator: " ").map(String.init)
        for k in stride(from: min(8, ctxWords.count), through: 1, by: -1) {
            let tail = ctxWords.suffix(k).joined(separator: " ")
            let head = words.prefix(k).joined(separator: " ").lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if head == tail {
                words.removeFirst(k)
                break
            }
        }
        words = Array(words.prefix(12))
        let out = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static let instructions = """
    Eres un autocompletado de escritura, no un asistente que responde al usuario. \
    Continúa el texto como si fueras su autor. Devuelve ÚNICAMENTE la continuación \
    más probable y útil, en el mismo idioma, tono y persona gramatical.

    Prioriza completar la intención concreta ya visible: una petición, explicación, \
    lista, mensaje o fragmento de código. Prefiere detalles específicos sugeridos \
    por el contexto frente a frases genéricas. Escribe entre 2 y 10 palabras; puedes \
    terminar antes si completas claramente la idea. No repitas el texto, no lo \
    contestes, no añadas comillas, etiquetas ni explicaciones.

    Ejemplos:
    Texto: "quiero que revises el código y"
    Respuesta: me digas si hay errores
    Texto: "create a new branch and"
    Respuesta: push the changes to it
    Texto: "El problema principal de esta propuesta es"
    Respuesta: que no define cómo mediremos el impacto
    Texto: "Podemos quedar mañana a las"
    Respuesta: diez y revisar juntos los cambios
    """

    static let wordInstructions = """
    El usuario está escribiendo una palabra y te da su texto, que acaba en un \
    fragmento de palabra. Responde ÚNICAMENTE con 4 palabras completas candidatas \
    que probablemente esté escribiendo, separadas por comas, sin explicar nada. \
    Deben empezar por el fragmento (puedes añadir tildes), o contener sus \
    letras en orden si parece una abreviatura sin vocales. Incluye términos \
    técnicos de programación si encajan con el contexto.

    Ejemplos:
    Texto: "quiero refac"
    Fragmento: "refac"
    Respuesta: refactorizar, refactoriza, refactorices, refactorización
    Texto: "limpia el tcld"
    Fragmento: "tcld"
    Respuesta: teclado, teclados, teclado
    """

    /// Parse a comma/newline-separated word list, keeping only real extensions
    /// of the typed fragment.
    static func cleanWordList(_ raw: String, partial: String) -> [String] {
        let normPartial = String(partial.lowercased().map(Lexicon.baseKey))
        var seen = Set<String>()
        var out: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let word = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«» .;:"))
            guard !word.isEmpty, !word.contains(" ") else { continue }
            let norm = String(word.lowercased().map(Lexicon.baseKey))
            // Accept prefix extensions and abbreviation expansions (subsequence).
            guard norm.hasPrefix(normPartial) || Lexicon.isSubsequence(normPartial, of: norm),
                  word.count > partial.count,
                  !seen.contains(norm) else { continue }
            seen.insert(norm)
            out.append(word)
            if out.count == 4 { break }
        }
        return out
    }
}

// MARK: - Apple system model (macOS 26+, zero setup)

@available(macOS 26.0, *)
final class SystemModelProvider: CompletionProvider {
    private let warmup: LanguageModelSession

    init?() {
        guard SystemLanguageModel.default.availability == .available else {
            NSLog("GlideBoard: system language model unavailable (%@)",
                  String(describing: SystemLanguageModel.default.availability))
            return nil
        }
        // Keep one session prewarmed so the model stays resident; actual
        // requests use fresh sessions so the transcript never grows.
        warmup = LanguageModelSession(instructions: CompletionCleaner.instructions)
        warmup.prewarm()
    }

    func complete(context: String) async throws -> String? {
        let session = LanguageModelSession(instructions: CompletionCleaner.instructions)
        let options = GenerationOptions(temperature: 0.15, maximumResponseTokens: 24)
        let prompt = "Texto hasta el cursor:\n\(context)\n\nContinuación:"
        let start = Date()
        let response = try await session.respond(to: prompt, options: options)
        let cleaned = CompletionCleaner.clean(response.content, context: context)
        QueryLog.shared.record(kind: "✦ frase", isPhrase: true, engine: "Apple",
                               ms: Int(-start.timeIntervalSinceNow * 1000),
                               context: context, raw: response.content,
                               cleaned: cleaned ?? "(nada)")
        return cleaned
    }

    func suggestWords(context: String, partial: String) async throws -> [String] {
        let session = LanguageModelSession(instructions: CompletionCleaner.wordInstructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 30)
        let prompt = "Texto: \"\(context)\"\nFragmento: \"\(partial)\"\nRespuesta:"
        let start = Date()
        let response = try await session.respond(to: prompt, options: options)
        let cleaned = CompletionCleaner.cleanWordList(response.content, partial: partial)
        QueryLog.shared.record(kind: "palabra «\(partial)»", isPhrase: false, engine: "Apple",
                               ms: Int(-start.timeIntervalSinceNow * 1000),
                               context: context, raw: response.content,
                               cleaned: cleaned.isEmpty ? "(nada)" : cleaned.joined(separator: ", "))
        return cleaned
    }
}

// MARK: - Ollama (local HTTP server, user-selectable model)

final class OllamaProvider: CompletionProvider {
    private func generate(prompt: String, maxTokens: Int, temperature: Double) async throws -> String? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "model": Settings.ollamaModel,
            "prompt": prompt,
            "stream": false,
            "think": false,
            // Keep the model resident between keystrokes (avoids cold reloads)
            // and cap the context window — autocomplete never needs more than a
            // couple thousand tokens, and the default 16K+ just bloats the KV
            // cache and slows attention.
            "keep_alive": "30m",
            "options": [
                "num_predict": maxTokens,
                "temperature": temperature,
                "num_ctx": 2048
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = obj["response"] as? String else { return nil }
        return response
    }

    func complete(context: String) async throws -> String? {
        let prompt = CompletionCleaner.instructions
            + "\n\nTexto hasta el cursor:\n\(context)\n\nContinuación:"
        let start = Date()
        guard let response = try await generate(prompt: prompt, maxTokens: 24, temperature: 0.15) else { return nil }
        let cleaned = CompletionCleaner.clean(response, context: context)
        QueryLog.shared.record(kind: "✦ frase", isPhrase: true,
                               engine: "Ollama (\(Settings.ollamaModel))",
                               ms: Int(-start.timeIntervalSinceNow * 1000),
                               context: context, raw: response, cleaned: cleaned ?? "(nada)")
        return cleaned
    }

    func suggestWords(context: String, partial: String) async throws -> [String] {
        let prompt = CompletionCleaner.wordInstructions
            + "\n\nTexto: \"\(context)\"\nFragmento: \"\(partial)\"\nRespuesta:"
        let start = Date()
        guard let response = try await generate(prompt: prompt, maxTokens: 30, temperature: 0.2) else { return [] }
        let cleaned = CompletionCleaner.cleanWordList(response, partial: partial)
        QueryLog.shared.record(kind: "palabra «\(partial)»", isPhrase: false,
                               engine: "Ollama (\(Settings.ollamaModel))",
                               ms: Int(-start.timeIntervalSinceNow * 1000),
                               context: context, raw: response,
                               cleaned: cleaned.isEmpty ? "(nada)" : cleaned.joined(separator: ", "))
        return cleaned
    }
}
