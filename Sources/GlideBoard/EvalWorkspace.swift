import Foundation
import CryptoKit

/// Exports the app's phrase-completion activity as an Eval Studio workspace:
/// an `evals/` directory with manifest, suite, cases, and imported runs/results.
///
/// Two case sources feed the suite:
/// - Live captures: every phrase query (context + what the engine suggested)
///   becomes a case once we know the ground truth — the words the user
///   actually typed after that context, extracted when the composer is sent.
///   The engine's suggestion at that moment is exported as a run result, so
///   the current baseline can be scored in Eval Studio.
/// - History bootstrap: persisted sent texts are cut at word boundaries into
///   (context, real continuation) pairs.
///
/// Case IDs are derived from SHA-256 of (context + continuation), so both
/// sources are idempotent: re-exporting never duplicates a case.
final class EvalExporter {

    // Fixed identities for the "phrase completion (ghost)" product action.
    private static let actionId = "b7e3a1c4-9d2f-4a6b-8c5e-1f0d2b3a4c5d"
    private static let suiteId = "e1f2a3b4-c5d6-4e7f-8a9b-0c1d2e3f4a5b"
    private static let suiteDirName = "glideboard.phrase-completion"

    private let root: URL
    private let fm = FileManager.default

    private struct Pending {
        let query: ModelQuery
    }
    private var pending: [Pending] = []

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Setup

    /// The workspace lives in the repo (`<repo>/evals`) so Eval Studio can be
    /// pointed at it. The repo root is derived from this source file's path at
    /// build time; a `evalsDirectory` default overrides it if the binary ever
    /// runs away from the repo.
    init?() {
        if let override = UserDefaults.standard.string(forKey: "evalsDirectory"), !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let repo = URL(fileURLWithPath: #filePath)      // Sources/GlideBoard/EvalWorkspace.swift
                .deletingLastPathComponent()                 // Sources/GlideBoard
                .deletingLastPathComponent()                 // Sources
                .deletingLastPathComponent()                 // repo root
            guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.swift").path) else {
                NSLog("GlideBoard: eval export disabled — repo not found at %@ (set the evalsDirectory default)", repo.path)
                return nil
            }
            root = repo.appendingPathComponent("evals", isDirectory: true)
        }
        ensureScaffold()
    }

    private var suiteDir: URL { root.appendingPathComponent("suites/\(Self.suiteDirName)", isDirectory: true) }
    private var casesDir: URL { suiteDir.appendingPathComponent("cases", isDirectory: true) }
    private var runsDir: URL { root.appendingPathComponent("runs", isDirectory: true) }

    private func ensureScaffold() {
        for dir in [casesDir, runsDir, root.appendingPathComponent("annotations", isDirectory: true)] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let manifest = root.appendingPathComponent("manifest.json")
        if !fm.fileExists(atPath: manifest.path) {
            writeJSON([
                "schemaVersion": "1",
                "workspaceName": "GlideBoard phrase completion",
                "createdAt": Self.iso.string(from: Date())
            ], to: manifest)
        }
    }

    // MARK: - Live capture

    /// Remember a phrase query until its ground truth is known. Word queries
    /// are ignored — the suite evaluates phrase continuation only.
    func capture(_ query: ModelQuery) {
        guard query.isPhrase else { return }
        pending.append(Pending(query: query))
        // Expire captures the user abandoned (composer cleared, panel closed…).
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        pending = pending.suffix(300).filter { $0.query.date > cutoff }
    }

    /// The composer was sent: `sentText` is the final truth. Every pending
    /// capture whose context appears in it becomes a case (what should have
    /// been suggested) plus a result (what the engine actually suggested).
    func finalize(sentText: String) {
        guard !pending.isEmpty else { return }
        var remaining: [Pending] = []
        var wroteCases = false
        for item in pending {
            guard let continuation = Self.continuation(after: item.query.context, in: sentText) else {
                remaining.append(item)
                continue
            }
            let caseId = writeCase(context: item.query.context,
                                   continuation: continuation,
                                   source: "live",
                                   note: "Capturado en vivo (fuente de contexto: \(item.query.source)).")
            writeResult(for: item.query, caseId: caseId)
            wroteCases = true
        }
        pending = remaining
        if wroteCases { rebuildSuite() }
    }

    /// What the user typed right after `context` inside `finalText`, or nil if
    /// the text was edited so much the context no longer appears. Matches a
    /// shrinking word-suffix of the context so mid-text edits before the
    /// capture point don't break the lookup.
    static func continuation(after context: String, in finalText: String) -> String? {
        let ctxWords = context.split(separator: " ")
        guard ctxWords.count >= 2 else { return nil }
        for k in stride(from: min(8, ctxWords.count), through: 2, by: -1) {
            let tail = ctxWords.suffix(k).joined(separator: " ")
            guard let range = finalText.range(of: tail, options: [.backwards, .caseInsensitive]) else { continue }
            let after = finalText[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let words = after.split(separator: " ").prefix(12)
            guard words.count >= 2 else { return nil }
            return words.joined(separator: " ")
        }
        return nil
    }

    // MARK: - History bootstrap

    /// Cut each persisted sent text at word boundaries into cases. Idempotent:
    /// deterministic case IDs make re-runs no-ops.
    func bootstrapFromHistory(_ url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        struct StoredEntry: Codable { let date: Date; let text: String }
        let decoder = JSONDecoder()
        var wrote = false
        for line in contents.split(separator: "\n") {
            guard let entry = try? decoder.decode(StoredEntry.self, from: Data(line.utf8)) else { continue }
            let words = entry.text.split(separator: " ").map(String.init)
            guard words.count >= 6 else { continue }
            let cuts = Set([max(3, words.count * 2 / 5), min(words.count - 2, words.count * 7 / 10)])
            for cut in cuts where cut >= 3 && cut <= words.count - 2 {
                let context = words[..<cut].joined(separator: " ")
                let continuation = words[cut...].prefix(12).joined(separator: " ")
                _ = writeCase(context: context, continuation: continuation, source: "history",
                              note: "Generado cortando un texto real del histórico.")
                wrote = true
            }
        }
        if wrote { rebuildSuite() }
    }

    // MARK: - Case

    /// Write (or skip, if it already exists) one case file. Returns its ID.
    private func writeCase(context: String, continuation: String,
                           source: String, note: String) -> String {
        let caseId = Self.deterministicUUID("case|\(context)|\(continuation)")
        let url = casesDir.appendingPathComponent("\(caseId).case.json")
        guard !fm.fileExists(atPath: url.path) else { return caseId }

        let prompt = CompletionCleaner.instructions
            + "\n\nTexto hasta el cursor:\n\(context)\n\nContinuación:"
        let ctxTail = context.split(separator: " ").suffix(5).joined(separator: " ")
        let contTail = continuation.split(separator: " ").prefix(4).joined(separator: " ")
        writeJSON([
            "schemaVersion": "1",
            "caseId": caseId,
            "actionId": Self.actionId,
            "name": "…\(ctxTail) → \(contTail)…",
            "note": note,
            "createdAt": Self.iso.string(from: Date()),
            "createdBy": ["source": "glideboard", "capture": source],
            "input": ["context": context],
            "promptTemplate": [
                "format": "text",
                "templateId": "glideboard.phrase-completion.v1",
                "text": CompletionCleaner.instructions + "\n\nTexto hasta el cursor:\n{{context}}\n\nContinuación:"
            ],
            "promptVariables": ["context": context],
            "renderedPrompt": ["format": "text", "text": prompt],
            "expectedOutput": [
                "kind": "continuation",
                "text": continuation,
                "criteria": [
                    "Coincide con la intención real del usuario: «\(continuation)»",
                    "Mismo idioma, tono y persona gramatical que el contexto",
                    "No repite el contexto ni lo responde como asistente"
                ]
            ],
            "source": ["app": "GlideBoard"]
        ], to: url)
        return caseId
    }

    /// Regenerate suite.json from the case files on disk (file names are the
    /// case IDs, so the directory listing is the source of truth).
    private func rebuildSuite() {
        let ids = ((try? fm.contentsOfDirectory(atPath: casesDir.path)) ?? [])
            .filter { $0.hasSuffix(".case.json") }
            .map { String($0.dropLast(".case.json".count)) }
            .sorted()
        writeJSON([
            "schemaVersion": "1",
            "suiteId": Self.suiteId,
            "actionId": Self.actionId,
            "name": "Continuación de frase (ghost)",
            "description": "Contextos reales de escritura con la continuación que el usuario escribió de verdad. Un buen resultado predice esas palabras (o su arranque).",
            "caseIds": ids
        ], to: suiteDir.appendingPathComponent("suite.json"))
    }

    // MARK: - Imported run/result (the live engine's baseline)

    /// Map the engine label recorded by QueryLog onto an Eval Studio runtime.
    private static func runtime(forEngine engine: String) -> (provider: String, model: String) {
        if engine.hasPrefix("Ollama"),
           let open = engine.firstIndex(of: "("), let close = engine.lastIndex(of: ")"),
           open < close {
            return ("ollama", String(engine[engine.index(after: open)..<close]))
        }
        return ("apple", "on-device")
    }

    private func writeResult(for query: ModelQuery, caseId: String) {
        let (provider, model) = Self.runtime(forEngine: query.engine)
        let day = ISO8601DateFormatter.string(from: query.date, timeZone: .current,
                                              formatOptions: [.withFullDate])
        let slug = provider == "ollama" ? "ollama-" + model.replacingOccurrences(of: ":", with: "-") : "apple"
        let runId = "live-\(day)-\(slug)"
        let runDir = runsDir.appendingPathComponent(runId, isDirectory: true)
        let resultsDir = runDir.appendingPathComponent("results", isDirectory: true)
        try? fm.createDirectory(at: resultsDir, withIntermediateDirectories: true)

        updateRun(id: runId, dir: runDir, provider: provider, model: model,
                  engine: query.engine, day: day, caseId: caseId)

        let prompt = CompletionCleaner.instructions
            + "\n\nTexto hasta el cursor:\n\(query.context)\n\nContinuación:"
        writeJSON([
            "schemaVersion": "1",
            "resultId": "\(runId).\(caseId)",
            "caseId": caseId,
            "runId": runId,
            "producer": "eval-studio",
            "createdAt": Self.iso.string(from: query.date),
            "runtime": ["provider": provider, "model": model, "temperature": 0.15],
            "promptVariables": ["context": query.context],
            "renderedPrompt": ["format": "text", "text": prompt],
            "rawOutput": query.raw,
            "parsedOutput": query.isEmpty ? NSNull() : query.cleaned,
            "status": "completed",
            "error": NSNull(),
            "usage": NSNull(),
            "latencyMs": query.ms
        ], to: resultsDir.appendingPathComponent("\(caseId).result.json"))
    }

    /// Create the day's run for this engine, or append the case to it.
    private func updateRun(id: String, dir: URL, provider: String, model: String,
                           engine: String, day: String, caseId: String) {
        let url = dir.appendingPathComponent("metadata.run.json")
        var run: [String: Any]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            run = existing
        } else {
            run = [
                "schemaVersion": "1",
                "runId": id,
                "name": "Capturas en vivo \(engine) \(day)",
                "actionId": Self.actionId,
                "producer": "eval-studio",
                "createdAt": Self.iso.string(from: Date()),
                "caseIds": [String](),
                "runtime": ["provider": provider, "model": model, "temperature": 0.15],
                "notes": "Importado desde GlideBoard: sugerencias reales del motor «\(engine)» capturadas mientras el usuario escribía.",
                "suiteId": Self.suiteId
            ]
        }
        var ids = run["caseIds"] as? [String] ?? []
        guard !ids.contains(caseId) else { return }
        ids.append(caseId)
        run["caseIds"] = ids
        writeJSON(run, to: url)
    }

    // MARK: - Plumbing

    /// SHA-256-based UUID so identical data always maps to the same case file.
    static func deterministicUUID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let h = { (r: Range<Int>) -> Substring in
            let s = hex.index(hex.startIndex, offsetBy: r.lowerBound)
            return hex[s..<hex.index(hex.startIndex, offsetBy: r.upperBound)]
        }
        return "\(h(0..<8))-\(h(8..<12))-\(h(12..<16))-\(h(16..<20))-\(h(20..<32))"
    }

    /// Write JSON to a temp file and rename into place, so Eval Studio never
    /// sees a half-written artifact during a refresh.
    private func writeJSON(_ object: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            NSLog("GlideBoard: could not serialize eval artifact %@", url.lastPathComponent)
            return
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-" + url.lastPathComponent)
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            NSLog("GlideBoard: could not write eval artifact %@: %@",
                  url.lastPathComponent, String(describing: error))
            try? fm.removeItem(at: tmp)
        }
    }
}
