import Foundation
@testable import GlideBoardCore

@MainActor
private final class RecordingExecutor: NumaActionExecuting {
    var performed: [(id: NumaActionID, invocation: NumaActionInvocation)] = []
    var presses = 0
    var releases = 0
    var outcome: NumaActionOutcome = .completed

    func performAction(_ id: NumaActionID,
                       from invocation: NumaActionInvocation) -> NumaActionOutcome {
        performed.append((id, invocation))
        return outcome
    }

    func pressPushToTalk() { presses += 1 }
    func releasePushToTalk() { releases += 1 }
}

@MainActor
func actionCatalogChecks() async {
    Checks.shared.begin("Action catalog")

    await Checks.shared.test("the catalog covers every action ID exactly once") {
        let ids = NumaActionCatalog.defaultDescriptors().map(\.id)
        try expectEqual(Set(ids).count, ids.count, "duplicate descriptor IDs")
        try expectEqual(Set(ids), Set(NumaActionID.allCases),
                        "descriptor list out of sync with NumaActionID")
    }

    await Checks.shared.test("raw IDs are the stable persisted contract") {
        // These values live in user defaults (shortcuts, recents): renaming
        // one is a data migration, not a refactor.
        try expectEqual(NumaActionID.toggleBoard.rawValue, "board.toggle")
        try expectEqual(NumaActionID.focusComposer.rawValue, "board.composer.focus")
        try expectEqual(NumaActionID.sendDraft.rawValue, "board.draft.send")
        try expectEqual(NumaActionID.toggleHandsFreeDictation.rawValue,
                        "dictation.handsfree.toggle")
        try expectEqual(NumaActionID.pushToTalk.rawValue, "dictation.pushtotalk")
        try expectEqual(NumaActionID.transformText.rawValue, "text.transform")
        try expectEqual(NumaActionID.toggleAttention.rawValue, "numa.attention.toggle")
        try expectEqual(NumaActionID.openSettings.rawValue, "app.settings.open")
        try expectEqual(NumaActionID.togglePalette.rawValue, "palette.toggle")
    }

    await Checks.shared.test("the palette shows only the curated actions") {
        // Curated 2026-07-16: the palette surfaces these four; every other
        // action keeps its menu/hotkey surface through the catalog.
        let visible = NumaActionCatalog.defaultDescriptors()
            .filter(\.showsInPalette)
            .map(\.id)
        try expectEqual(visible, [.toggleBoard, .toggleHandsFreeDictation,
                                  .toggleAttention, .openSettings])
    }

    await Checks.shared.test("execute routes through the executor with its surface") {
        let executor = RecordingExecutor()
        let catalog = NumaActionCatalog(executor: executor)
        let outcome = catalog.execute(.toggleBoard, from: .statusMenu)
        try expectEqual(outcome, .completed)
        try expectEqual(executor.performed.count, 1)
        try expectEqual(executor.performed[0].id, .toggleBoard)
        try expectEqual(executor.performed[0].invocation, .statusMenu)
    }

    await Checks.shared.test("push-to-talk never runs as a one-shot action") {
        let executor = RecordingExecutor()
        let catalog = NumaActionCatalog(executor: executor)
        let outcome = catalog.execute(.pushToTalk, from: .palette)
        guard case .unavailable(let reason) = outcome else {
            throw CheckFailure(message: "expected .unavailable, got \(outcome)",
                               location: #fileID)
        }
        try expectFalse(reason.isEmpty, "the explanation must not be empty")
        try expectTrue(executor.performed.isEmpty)
    }

    await Checks.shared.test("push-to-talk press/release reaches the executor") {
        let executor = RecordingExecutor()
        let catalog = NumaActionCatalog(executor: executor)
        catalog.pressPushToTalk()
        catalog.releasePushToTalk()
        try expectEqual(executor.presses, 1)
        try expectEqual(executor.releases, 1)
    }

    await Checks.shared.test("an unavailable action explains itself and never runs") {
        let executor = RecordingExecutor()
        let catalog = NumaActionCatalog(
            executor: executor,
            availability: { id in
                id == .toggleHandsFreeDictation
                    ? .unavailable("Still transcribing") : .available
            })
        let outcome = catalog.execute(.toggleHandsFreeDictation, from: .palette)
        try expectEqual(outcome, .unavailable("Still transcribing"))
        try expectTrue(executor.performed.isEmpty)
        let resolved = catalog.resolvedActions()
            .first { $0.descriptor.id == .toggleHandsFreeDictation }
        try expectEqual(try unwrap(resolved).availability.reason, "Still transcribing")
    }

    await Checks.shared.test("shortcut and voice metadata are only what was configured") {
        let executor = RecordingExecutor()
        let catalog = NumaActionCatalog(
            executor: executor,
            shortcut: { id in id == .toggleBoard ? (5, 2304) : nil },
            voicePhrase: { id in
                id == .toggleHandsFreeDictation ? "Numa, graba" : nil
            })
        for entry in catalog.resolvedActions() {
            switch entry.descriptor.id {
            case .toggleBoard:
                try expectEqual(try unwrap(entry.shortcut).keyCode, 5)
            case .toggleHandsFreeDictation:
                try expectNil(entry.shortcut, "unconfigured shortcut must stay nil")
                try expectEqual(entry.voicePhrase, "Numa, graba")
            default:
                try expectNil(entry.shortcut, "unconfigured shortcut must stay nil")
                try expectNil(entry.voicePhrase, "no invented voice phrases")
            }
        }
    }

    Checks.shared.begin("Palette search")

    let executor = RecordingExecutor()

    func entries(unavailable: Set<NumaActionID> = [])
        -> [NumaActionCatalog.ResolvedAction]
    {
        NumaActionCatalog(
            executor: executor,
            availability: { id in
                unavailable.contains(id) ? .unavailable("busy") : .available
            })
            .resolvedActions()
    }

    await Checks.shared.test("an empty query keeps stable catalog order") {
        // Push-to-talk is permanently unavailable as a one-shot action, so it
        // sinks last; everything else keeps catalog order.
        let results = PaletteSearch.results(query: "", entries: entries(), recents: [])
        let expected = NumaActionCatalog.defaultDescriptors().map(\.id)
            .filter { $0 != .pushToTalk } + [.pushToTalk]
        try expectEqual(results.map(\.descriptor.id), expected)
    }

    await Checks.shared.test("recent actions lead the empty query") {
        let results = PaletteSearch.results(
            query: "", entries: entries(),
            recents: [NumaActionID.openSettings.rawValue,
                      NumaActionID.transformText.rawValue])
        try expectEqual(results[0].descriptor.id, .openSettings)
        try expectEqual(results[1].descriptor.id, .transformText)
    }

    await Checks.shared.test("unavailable actions sink below available ones") {
        let results = PaletteSearch.results(
            query: "", entries: entries(unavailable: [.toggleBoard]), recents: [])
        try expectEqual(results.suffix(2).map(\.descriptor.id),
                        [.toggleBoard, .pushToTalk],
                        "unavailable actions in catalog order at the bottom")
    }

    await Checks.shared.test("search matches titles, aliases and keywords") {
        let all = entries()
        let byTitle = PaletteSearch.results(query: "send", entries: all, recents: [])
        try expectEqual(try unwrap(byTitle.first).descriptor.id, .sendDraft)
        let byAlias = PaletteSearch.results(query: "borrador", entries: all, recents: [])
        try expectTrue(byAlias.contains { $0.descriptor.id == .focusComposer })
        try expectTrue(byAlias.contains { $0.descriptor.id == .sendDraft })
        let byKeyword = PaletteSearch.results(query: "microphone", entries: all,
                                              recents: [])
        try expectTrue(byKeyword.contains { $0.descriptor.id == .toggleHandsFreeDictation })
        try expectFalse(byKeyword.contains { $0.descriptor.id == .openSettings })
    }

    await Checks.shared.test("matching is diacritic- and case-insensitive") {
        let all = entries()
        for query in ["atención", "ATENCION", "atencion"] {
            let results = PaletteSearch.results(query: query, entries: all, recents: [])
            try expectTrue(results.contains { $0.descriptor.id == .toggleAttention },
                           "query \(query) must find the attention action")
        }
    }

    await Checks.shared.test("every token of a multi-word query must match") {
        let all = entries()
        let results = PaletteSearch.results(query: "send draft", entries: all,
                                            recents: [])
        try expectEqual(try unwrap(results.first).descriptor.id, .sendDraft)
        let none = PaletteSearch.results(query: "send nonsense", entries: all,
                                         recents: [])
        try expectTrue(none.isEmpty)
    }

    await Checks.shared.test("results are deterministic for the same state") {
        let all = entries(unavailable: [.transformText])
        let recents = [NumaActionID.sendDraft.rawValue]
        let first = PaletteSearch.results(query: "t", entries: all, recents: recents)
        let second = PaletteSearch.results(query: "t", entries: all, recents: recents)
        try expectEqual(first.map(\.descriptor.id), second.map(\.descriptor.id))
    }

    Checks.shared.begin("Action shortcuts")

    await Checks.shared.test("optional shortcuts persist and clear per action") {
        Settings.actionShortcuts = [:]
        try expectTrue(Settings.actionShortcuts.isEmpty, "every action starts unset")
        var map = Settings.actionShortcuts
        map[NumaActionID.togglePalette.rawValue] = ActionShortcut(keyCode: 35,
                                                                  modifiers: 2304)
        Settings.actionShortcuts = map
        try expectEqual(Settings.actionShortcuts[NumaActionID.togglePalette.rawValue],
                        ActionShortcut(keyCode: 35, modifiers: 2304))
        map[NumaActionID.togglePalette.rawValue] = nil
        Settings.actionShortcuts = map
        try expectTrue(Settings.actionShortcuts.isEmpty)
    }

    await Checks.shared.test("conflicts name the action that owns the shortcut") {
        let owners: [(name: String, keyCode: UInt32, modifiers: UInt32)] = [
            ("Enviar el borrador", 36, 256),
            ("Command palette", 35, 2304)
        ]
        try expectEqual(ShortcutConflicts.conflict(keyCode: 35, modifiers: 2304,
                                                   among: owners),
                        "Command palette")
        try expectNil(ShortcutConflicts.conflict(keyCode: 35, modifiers: 256,
                                                 among: owners))
    }

    await Checks.shared.test("palette recents stay capped and deduplicated") {
        Settings.paletteRecents = []
        Settings.paletteRecents = (0..<12).map { "action.\($0)" }
        try expectEqual(Settings.paletteRecents.count, 8, "recents cap")
        Settings.paletteRecents = []
    }

    await Checks.shared.test("keycaps render modifiers in the native order") {
        let parts = PaletteRowView.keycapParts(keyCode: 35, modifiers: 2304)
        try expectEqual(parts, ["⌥", "⌘", "P"])
        let bare = PaletteRowView.keycapParts(keyCode: 49, modifiers: 0)
        try expectEqual(bare, ["Espacio"])
    }

    await Checks.shared.test("palette height fits results up to the visible cap") {
        let one = PaletteContentView().fittingHeight(for: 1)
        let seven = PaletteContentView().fittingHeight(for: 7)
        let fifty = PaletteContentView().fittingHeight(for: 50)
        try expectTrue(one < seven)
        try expectEqual(seven, fifty, "the panel never outgrows the row cap")
    }
}
