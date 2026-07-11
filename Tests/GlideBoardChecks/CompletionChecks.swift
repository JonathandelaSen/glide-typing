import Foundation
import ApplicationServices
@testable import GlideBoardCore

@MainActor
func completionChecks() async {
    let c = Checks.shared
    c.begin("Completion pipeline")

    await c.test("Ollama catalog extracts and sorts available model names") {
        let payload = """
        {
          "models": [
            { "name": "qwen3:4b" },
            { "name": "gemma3:1b" },
            { "name": "" }
          ]
        }
        """.data(using: .utf8)!
        try expectEqual(try OllamaModelCatalog.modelNames(from: payload),
                        ["gemma3:1b", "qwen3:4b"])
    }

    await c.test("model selector is enabled only for the Ollama engine") {
        try expectTrue(OllamaModelCatalog.isSelectorEnabled(for: "ollama"))
        try expectFalse(OllamaModelCatalog.isSelectorEnabled(for: "system"))
        try expectFalse(OllamaModelCatalog.isSelectorEnabled(for: "off"))
    }

    await c.test("focused-text target recognizes editable roles") {
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: kAXTextFieldRole as String, supportsTextSelection: false))
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: kAXTextAreaRole as String, supportsTextSelection: false))
        try expectFalse(FocusedFieldReader.isEditableTextTarget(
            role: kAXButtonRole as String, supportsTextSelection: false))
    }

    await c.test("a selectable page is not an editable target (Chromium)") {
        // Chromium answers AXSelectedTextRange on the whole page — web area,
        // groups, static text — so selection support alone must not turn a
        // read-only page into a dictation destination.
        try expectFalse(FocusedFieldReader.isEditableTextTarget(
            role: "AXWebArea", supportsTextSelection: true))
        try expectFalse(FocusedFieldReader.isEditableTextTarget(
            role: kAXGroupRole as String, supportsTextSelection: true))
        try expectFalse(FocusedFieldReader.isEditableTextTarget(
            role: kAXStaticTextRole as String, supportsTextSelection: true))
    }

    await c.test("web content inside editable ancestors accepts text") {
        // contenteditable/rich editors: Chromium marks the focused node with
        // AXEditableAncestor even when its role is a plain group or web area.
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: "AXWebArea", supportsTextSelection: true, hasEditableAncestor: true))
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: kAXGroupRole as String, supportsTextSelection: true,
            hasEditableAncestor: true))
    }

    await c.test("custom native editors keep the selection-range fallback") {
        // Non-container roles that expose a selection range (custom text
        // views without a standard role) still count as editable.
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: "AXCustomEditor", supportsTextSelection: true))
    }

    await c.test("Chromium nodes never editable by selection range alone") {
        // Chromium answers AXSelectedTextRange on every node — a focused
        // menu item in an Electron app must not become a dictation target.
        try expectFalse(FocusedFieldReader.isEditableTextTarget(
            role: "AXMenuItem", supportsTextSelection: true, isChromiumNode: true))
        try expectFalse(FocusedFieldReader.isEditableTextTarget(
            role: "AXCustomEditor", supportsTextSelection: true, isChromiumNode: true))
        // Positive signals still win: real inputs and contenteditable content.
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: kAXTextAreaRole as String, supportsTextSelection: true,
            isChromiumNode: true))
        try expectTrue(FocusedFieldReader.isEditableTextTarget(
            role: kAXGroupRole as String, supportsTextSelection: true,
            hasEditableAncestor: true, isChromiumNode: true))
    }

    await c.test("dictation log appends versioned timestamped lines") {
        let marker = "check-\(UUID().uuidString)"
        DictationLog.write(marker)
        let contents = (try? String(contentsOf: DictationLog.url, encoding: .utf8)) ?? ""
        guard let line = contents.split(separator: "\n").last(where: { $0.contains(marker) }) else {
            throw CheckFailure(message: "marker line missing from dictation log",
                               location: #fileID)
        }
        try expectTrue(line.contains("[v\(BuildVersion.code)]"))
    }

    await c.test("unknown targets still allow an insertion attempt") {
        try expectTrue(FocusedFieldReader.TextTargetStatus.unknown.canAttemptInsertion)
        try expectTrue(FocusedFieldReader.textTargetStatus(
            role: nil, supportsTextSelection: false).canAttemptInsertion)
    }

    await c.test("known non-editable targets block the insertion attempt") {
        try expectFalse(FocusedFieldReader.TextTargetStatus.notEditable.canAttemptInsertion)
        try expectFalse(FocusedFieldReader.textTargetStatus(
            role: kAXButtonRole as String, supportsTextSelection: false).canAttemptInsertion)
    }

    await c.test("contextForModel preserves trailing whitespace") {
        try expectEqual(CompletionCleaner.contextForModel("vamos a revisar esto "),
                        "vamos a revisar esto ")
    }

    await c.test("contextForModel keeps recent text without cutting a word") {
        let old = String(repeating: "antiguo ", count: 100)
        let result = CompletionCleaner.contextForModel(old + "contexto reciente",
                                                       maxLength: 40)
        try expectEqual(result, "antiguo antiguo contexto reciente")
        try expectTrue(result.count <= 40)
        try expectTrue(result.hasPrefix("antiguo"), "must not start mid-word: \(result)")
    }

    await c.test("cleaner rejects meta commentary instead of offering it") {
        try expectNil(CompletionCleaner.clean("Respuesta: puedes terminar la frase",
                                              context: "Creo que"))
        try expectNil(CompletionCleaner.clean("No hay suficiente contexto",
                                              context: "Creo que"))
    }

    await c.test("cleaner removes the echoed context, keeps the continuation") {
        try expectEqual(CompletionCleaner.clean("revisar el código antes de enviarlo",
                                                context: "Tenemos que revisar el código"),
                        "antes")
    }

    await c.test("cleaner strips prompt delimiters") {
        try expectEqual(CompletionCleaner.clean("<<<necesitamos>>><<<soluciones>>>",
                                                context: "fox ese"),
                        "necesitamos")
        try expectEqual(CompletionCleaner.clean("fox ese <<<necesitamos>>>",
                                                context: "fox ese"),
                        "necesitamos")
    }

    await c.test("cleaner keeps only the first word and first line") {
        try expectEqual(CompletionCleaner.clean("mañana y luego\notra cosa",
                                                context: "hasta"),
                        "mañana")
        try expectNil(CompletionCleaner.clean("", context: "hasta"))
    }

    await c.test("phrasePrompt includes the target line only when present") {
        let with = CompletionCleaner.phrasePrompt(context: "Hola", target: "Mail — Re: informe")
        try expectTrue(with.contains("Writing in: Mail — Re: informe"))
        try expectTrue(with.hasSuffix("Sentence: Hola"))
        let without = CompletionCleaner.phrasePrompt(context: "Hola")
        try expectFalse(without.contains("Writing in:"))
    }
}
