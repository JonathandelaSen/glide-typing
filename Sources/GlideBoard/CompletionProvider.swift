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
    /// Where the text will land ("Mail — Re: informe"), from the AX tree.
    let target: String?
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

    /// Ghost pipeline tallies for the decision-flow diagram (main thread).
    private(set) var phraseMemoryHits = 0
    private(set) var phraseLLMCalls = 0

    func record(kind: String, isPhrase: Bool, engine: String, ms: Int,
                context: String, target: String? = nil, raw: String, cleaned: String) {
        let query = ModelQuery(kind: kind, isPhrase: isPhrase, engine: engine, ms: ms,
                               source: currentSource, context: context, target: target,
                               raw: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                               cleaned: cleaned)
        DispatchQueue.main.async {
            if query.isPhrase {
                if query.engine.hasPrefix("Memoria") { self.phraseMemoryHits += 1 }
                else { self.phraseLLMCalls += 1 }
            }
            self.sink?(query)
        }
    }

    func recordPhraseAccepted() {
        DispatchQueue.main.async { self.phraseAcceptedSink?() }
    }
}

/// A source of short phrase completions ("ghost text").
protocol CompletionProvider {
    /// `target` is a one-line description of where the text will land
    /// ("Slack — #dev"), read from the AX tree — it disambiguates tone and
    /// vocabulary in ways the sentence alone cannot.
    func complete(context: String, target: String?) async throws -> String?
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
        words = Array(words.prefix(1))
        let out = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Short-bet prompt, validated verbatim in the user's eval platform:
    /// a single next word maximizes acceptability.
    static let instructions = "Continue the sentence with the next word, only one."

    /// The exact plain-text prompt sent for a phrase completion. Also the
    /// shape exported to the eval workspace — keep both in sync by using
    /// only this function to build it. The optional target line tells the
    /// model where the text is being written (app, window, field).
    static func phrasePrompt(context: String, target: String? = nil) -> String {
        var prompt = instructions
        if let target, !target.isEmpty {
            prompt += "\nWriting in: " + target
        }
        return prompt + "\nSentence: " + context
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

    func complete(context: String, target: String?) async throws -> String? {
        let session = LanguageModelSession(instructions: CompletionCleaner.instructions)
        let options = GenerationOptions(temperature: 0.15, maximumResponseTokens: 8)
        var prompt = ""
        if let target, !target.isEmpty { prompt += "Writing in: \(target)\n" }
        prompt += "Sentence: \(context)"
        let start = Date()
        let response = try await session.respond(to: prompt, options: options)
        let cleaned = CompletionCleaner.clean(response.content, context: context)
        QueryLog.shared.record(kind: "✦ frase", isPhrase: true, engine: "Apple",
                               ms: Int(-start.timeIntervalSinceNow * 1000),
                               context: context, target: target, raw: response.content,
                               cleaned: cleaned ?? "(nada)")
        return cleaned
    }

}

// MARK: - Ollama (local HTTP server, user-selectable model)

final class OllamaProvider: CompletionProvider {
    private func generate(prompt: String, maxTokens: Int, temperature: Double,
                          stop: [String] = []) async throws -> String? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        var options: [String: Any] = [
            "num_predict": maxTokens,
            "temperature": temperature,
            "num_ctx": 2048
        ]
        if !stop.isEmpty { options["stop"] = stop }
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
            "options": options
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = obj["response"] as? String else { return nil }
        return response
    }

    func complete(context: String, target: String?) async throws -> String? {
        let prompt = CompletionCleaner.phrasePrompt(context: context, target: target)
        let start = Date()
        guard let response = try await generate(prompt: prompt, maxTokens: 8,
                                                temperature: 0.15, stop: ["\n"]) else { return nil }
        let cleaned = CompletionCleaner.clean(response, context: context)
        QueryLog.shared.record(kind: "✦ frase", isPhrase: true,
                               engine: "Ollama (\(Settings.ollamaModel))",
                               ms: Int(-start.timeIntervalSinceNow * 1000),
                               context: context, target: target,
                               raw: response, cleaned: cleaned ?? "(nada)")
        return cleaned
    }

}
