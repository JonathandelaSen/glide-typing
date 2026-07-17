import AppKit

/// Applies a plan best-effort: one failed window never rolls back the others,
/// every rule reports its own outcome, and a retry re-runs single rules. The
/// executor knows services and protocols, never menu items.
@MainActor
final class WorkspaceProfileExecutor {
    private let spaceManager: SpaceManaging
    private let catalog: WorkspaceWindowCatalog
    private let launcher: WorkspaceApplicationLauncher
    private let recipes: WorkspaceWindowRecipeRegistry
    private let undoStore: WorkspaceUndoStore

    init(spaceManager: SpaceManaging, catalog: WorkspaceWindowCatalog,
         launcher: WorkspaceApplicationLauncher,
         recipes: WorkspaceWindowRecipeRegistry, undoStore: WorkspaceUndoStore) {
        self.spaceManager = spaceManager
        self.catalog = catalog
        self.launcher = launcher
        self.recipes = recipes
        self.undoStore = undoStore
    }

    func apply(_ profile: WorkspaceProfile,
               limitToRuleIDs: Set<UUID>? = nil) async -> WorkspaceApplyReport {
        var effective = profile
        if let limitToRuleIDs {
            effective.rules = profile.rules.filter { limitToRuleIDs.contains($0.id) }
        }

        func blockedReport(_ reason: String) -> WorkspaceApplyReport {
            WorkspaceApplyReport(
                profileID: profile.id, profileName: profile.name,
                results: effective.rules.filter { !$0.isExcluded }
                    .map { WorkspaceRuleResult(rule: $0, outcome: .blocked(reason)) },
                extraWindows: [], diagnostics: [reason], finishedAt: Date())
        }

        if case .unavailable(let reason) = spaceManager.capability {
            return blockedReport(reason)
        }

        let current = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        let mismatches = DisplayConfigurationResolver.mismatchReasons(
            saved: profile.display, current: current)
        guard mismatches.isEmpty else {
            return blockedReport("Display configuration differs: "
                + mismatches.joined(separator: "; "))
        }
        guard let savedDisplay = profile.display.displays.first(where: \.isPrimary)
                ?? profile.display.displays.first,
              let currentUUID = DisplayConfigurationResolver.displayUUIDMapping(
                saved: profile.display, current: current)[savedDisplay.uuid],
              let currentDisplay = current.displays.first(where: { $0.uuid == currentUUID })
        else {
            return blockedReport("The captured display could not be resolved")
        }

        let displayUUID = currentDisplay.uuid
        let visibleFrame = currentDisplay.visibleFrame
        var spaceIDByOrdinal: [Int: UInt64] = [:]
        for (index, spaceID) in spaceManager
            .orderedUserSpaceIDs(displayUUID: displayUUID).enumerated() {
            spaceIDByOrdinal[index + 1] = spaceID
        }

        func planNow() -> (WorkspaceApplyPlan, [UInt32: WorkspaceWindowCatalog.Entry]) {
            let entries = catalog.snapshot(spaceManager: spaceManager,
                                           displayUUID: displayUUID)
            let byID = Dictionary(entries.map { ($0.live.cgWindowID, $0) },
                                  uniquingKeysWith: { first, _ in first })
            let plan = WorkspacePlanBuilder.build(WorkspacePlanInput(
                profile: effective,
                liveWindows: entries.map(\.live),
                runningBundleIDs: catalog.runningBundleIDs(),
                spaceIDByOrdinal: spaceIDByOrdinal,
                visibleFrame: visibleFrame,
                creationRecipeBundleIDs: recipes.creationRecipeBundleIDs))
            return (plan, byID)
        }

        var (plan, entriesByID) = planNow()
        recordUndoSnapshot(profileName: profile.name, plan: plan,
                           entriesByID: entriesByID,
                           merging: limitToRuleIDs != nil)

        var failureByRuleID: [UUID: String] = [:]
        var provenance: [UUID: WorkspaceRuleOutcome] = [:]

        let launchBundles = Set(plan.rulePlans
            .filter { $0.action == .launchAndAdopt }.map(\.rule.bundleID))
        for bundleID in launchBundles.sorted() {
            let affected = plan.rulePlans
                .filter { $0.rule.bundleID == bundleID && $0.action == .launchAndAdopt }
                .map(\.rule.id)
            switch await launcher.ensureRunning(bundleID: bundleID) {
            case .success:
                affected.forEach { provenance[$0] = .launched }
                _ = await waitForWindowCount(bundleID: bundleID, atLeast: 1,
                                             displayUUID: displayUUID, timeout: 10)
            case .failure(let reason):
                affected.forEach { failureByRuleID[$0] = reason }
            }
        }
        if !launchBundles.isEmpty {
            (plan, entriesByID) = planNow()
        }

        var createRuleIDsByBundle: [String: [UUID]] = [:]
        for rulePlan in plan.rulePlans
            where rulePlan.action == .createWindow
                && failureByRuleID[rulePlan.rule.id] == nil {
            createRuleIDsByBundle[rulePlan.rule.bundleID, default: []]
                .append(rulePlan.rule.id)
        }
        for (bundleID, ruleIDs) in createRuleIDsByBundle.sorted(by: { $0.key < $1.key }) {
            guard let recipe = recipes.recipe(bundleID: bundleID) else {
                ruleIDs.forEach {
                    failureByRuleID[$0] = "No tested window recipe for \(bundleID)"
                }
                continue
            }
            guard let app = launcher.runningApp(bundleID: bundleID) else {
                ruleIDs.forEach { failureByRuleID[$0] = "\(bundleID) is not running" }
                continue
            }
            for ruleID in ruleIDs {
                let before = windowCount(bundleID: bundleID, displayUUID: displayUUID)
                guard await recipe.createWindow(app) else {
                    failureByRuleID[ruleID] = "The window recipe failed to trigger"
                    continue
                }
                if await waitForWindowCount(bundleID: bundleID, atLeast: before + 1,
                                            displayUUID: displayUUID, timeout: 8) {
                    provenance[ruleID] = .created
                } else {
                    failureByRuleID[ruleID] = "The new window never appeared"
                }
            }
        }
        if !createRuleIDsByBundle.isEmpty {
            (plan, entriesByID) = planNow()
        }

        var results: [WorkspaceRuleResult] = []
        for rulePlan in plan.rulePlans {
            let rule = rulePlan.rule
            if let failure = failureByRuleID[rule.id] {
                results.append(WorkspaceRuleResult(rule: rule, outcome: .failed(failure)))
                continue
            }
            func success(afterMove: Bool) -> WorkspaceRuleOutcome {
                provenance[rule.id] ?? (afterMove ? .applied : .satisfied)
            }
            switch rulePlan.action {
            case .blocked(let reason):
                results.append(WorkspaceRuleResult(rule: rule, outcome: .blocked(reason)))
            case .none:
                results.append(WorkspaceRuleResult(rule: rule,
                                                   outcome: success(afterMove: false)))
            case .move:
                guard let windowID = rulePlan.matchedWindowID,
                      let entry = entriesByID[windowID],
                      let targetSpace = rulePlan.targetSpaceID,
                      let targetFrame = rulePlan.targetFrame else {
                    results.append(WorkspaceRuleResult(
                        rule: rule, outcome: .failed("The plan lost its window")))
                    continue
                }
                if let problem = await place(entry: entry, rulePlan: rulePlan,
                                             targetSpace: targetSpace,
                                             targetFrame: targetFrame) {
                    results.append(WorkspaceRuleResult(rule: rule,
                                                       outcome: .failed(problem)))
                } else {
                    results.append(WorkspaceRuleResult(rule: rule,
                                                       outcome: success(afterMove: true)))
                }
            case .launchAndAdopt:
                results.append(WorkspaceRuleResult(
                    rule: rule, outcome: .failed("No window appeared after launching")))
            case .createWindow:
                results.append(WorkspaceRuleResult(
                    rule: rule, outcome: .failed("No window was created for this slot")))
            }
        }

        restoreStacking(plan: plan, results: results, entriesByID: entriesByID)

        var diagnostics = plan.diagnostics
        diagnostics.append(contentsOf: DisplayConfigurationResolver
            .currentPrerequisiteIssues())
        return WorkspaceApplyReport(profileID: profile.id, profileName: profile.name,
                                    results: results,
                                    extraWindows: plan.extraWindows,
                                    diagnostics: diagnostics, finishedAt: Date())
    }

    func undoLastApply() async -> [String] {
        guard let snapshot = undoStore.latest else { return ["Nothing to undo"] }
        let current = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        var validSpaces = Set<UInt64>()
        for display in current.displays {
            validSpaces.formUnion(spaceManager.orderedUserSpaceIDs(displayUUID: display.uuid))
        }
        guard let displayUUID = current.displays.first(where: \.isPrimary)?.uuid
            ?? current.displays.first?.uuid else { return ["No display detected"] }
        let entries = catalog.snapshot(spaceManager: spaceManager,
                                       displayUUID: displayUUID)
        let byID = Dictionary(entries.map { ($0.live.cgWindowID, $0) },
                              uniquingKeysWith: { first, _ in first })

        var lines: [String] = []
        for state in snapshot.windows {
            guard let entry = byID[state.cgWindowID] else {
                lines.append("\(state.slotName): the window no longer exists")
                continue
            }
            if entry.window.isMinimized() && !state.wasMinimized {
                entry.window.setMinimized(false)
                _ = await poll(timeout: 2) { !entry.window.isMinimized() }
            }
            if let spaceID = state.spaceID {
                if validSpaces.contains(spaceID) {
                    if spaceManager.spaceID(ofWindow: state.cgWindowID) != spaceID {
                        spaceManager.moveWindows([state.cgWindowID], toSpace: spaceID)
                        _ = await poll(timeout: 2) {
                            self.spaceManager.spaceID(ofWindow: state.cgWindowID) == spaceID
                        }
                    }
                } else {
                    lines.append("\(state.slotName): its original Space is gone; "
                        + "only the frame was restored")
                }
            }
            entry.window.setFrame(state.frame)
            _ = await poll(timeout: 2) {
                entry.window.frame().map {
                    WorkspaceGeometry.approximatelyEqual($0, state.frame, tolerance: 4)
                } ?? false
            }
            if state.wasMinimized && !entry.window.isMinimized() {
                entry.window.setMinimized(true)
            }
            lines.append("\(state.slotName): restored")
        }

        for group in Dictionary(grouping: snapshot.windows, by: \.spaceID).values {
            for state in group.sorted(by: { $0.stackingRank > $1.stackingRank })
                where !state.wasMinimized {
                byID[state.cgWindowID]?.window.raise()
            }
        }
        undoStore.clear()
        return lines
    }

    // MARK: - Steps

    /// Only windows this apply intends to move enter the snapshot. A retry
    /// merges into the existing snapshot, keeping the older (pre-apply)
    /// state for windows already recorded.
    private func recordUndoSnapshot(profileName: String, plan: WorkspaceApplyPlan,
                                    entriesByID: [UInt32: WorkspaceWindowCatalog.Entry],
                                    merging: Bool) {
        var rankByWindowID: [UInt32: Int] = [:]
        for (index, windowID) in catalog.allWindowIDsFrontToBack().enumerated() {
            rankByWindowID[windowID] = index
        }
        var states = plan.rulePlans.compactMap { rulePlan -> WorkspaceUndoWindowState? in
            guard rulePlan.action == .move,
                  let windowID = rulePlan.matchedWindowID,
                  let entry = entriesByID[windowID] else { return nil }
            return WorkspaceUndoWindowState(
                cgWindowID: windowID,
                bundleID: entry.live.bundleID,
                slotName: rulePlan.rule.slotName,
                spaceID: entry.live.spaceID,
                frame: entry.live.frame,
                wasMinimized: entry.live.isMinimized,
                stackingRank: rankByWindowID[windowID] ?? Int.max)
        }
        if merging, let previous = undoStore.latest {
            let known = Set(previous.windows.map(\.cgWindowID))
            states = previous.windows + states.filter { !known.contains($0.cgWindowID) }
            undoStore.replace(WorkspaceUndoSnapshot(profileName: previous.profileName,
                                                    takenAt: previous.takenAt,
                                                    windows: states))
        } else {
            undoStore.replace(WorkspaceUndoSnapshot(profileName: profileName,
                                                    takenAt: Date(), windows: states))
        }
    }

    private func place(entry: WorkspaceWindowCatalog.Entry,
                       rulePlan: WorkspaceRulePlan,
                       targetSpace: UInt64, targetFrame: CGRect) async -> String? {
        let window = entry.window
        let windowID = entry.live.cgWindowID
        if window.isMinimized() {
            window.setMinimized(false)
            guard await poll(timeout: 3, { !window.isMinimized() }) else {
                return "Could not unminimize the window"
            }
        }
        if spaceManager.spaceID(ofWindow: windowID) != targetSpace {
            spaceManager.moveWindows([windowID], toSpace: targetSpace)
            guard await poll(timeout: 3, {
                self.spaceManager.spaceID(ofWindow: windowID) == targetSpace
            }) else {
                return "The window did not land on Space \(rulePlan.rule.spaceOrdinal)"
            }
        }
        let currentFrame = window.frame()
        if currentFrame == nil || !WorkspaceGeometry.approximatelyEqual(
            currentFrame!, targetFrame, tolerance: 4) {
            window.setFrame(targetFrame)
            let accepted = await poll(timeout: 3) {
                window.frame().map {
                    WorkspaceGeometry.approximatelyEqual($0, targetFrame, tolerance: 4)
                } ?? false
            }
            guard accepted else {
                let got = window.frame().map {
                    "\(Int($0.width))×\(Int($0.height)) at (\(Int($0.origin.x)), \(Int($0.origin.y)))"
                } ?? "an unreadable frame"
                return "The window refused its frame; it reports \(got)"
            }
        }
        return nil
    }

    /// Best effort: windows are raised back-to-front per Space so the
    /// captured front window is raised last. Apps are never activated here —
    /// activation would switch Spaces mid-apply.
    private func restoreStacking(plan: WorkspaceApplyPlan,
                                 results: [WorkspaceRuleResult],
                                 entriesByID: [UInt32: WorkspaceWindowCatalog.Entry]) {
        let succeeded = Set(results.filter { !$0.outcome.isFailure }.map(\.rule.id))
        let placed = plan.rulePlans.filter {
            succeeded.contains($0.rule.id) && $0.matchedWindowID != nil
        }
        for (_, group) in Dictionary(grouping: placed,
                                     by: { $0.targetSpaceID ?? 0 }) {
            guard group.count > 1 || group.first?.rule.stackingRank == 0 else { continue }
            for rulePlan in group.sorted(by: { $0.rule.stackingRank > $1.rule.stackingRank }) {
                guard let windowID = rulePlan.matchedWindowID else { continue }
                entriesByID[windowID]?.window.raise()
            }
        }
    }

    private func windowCount(bundleID: String, displayUUID: String) -> Int {
        catalog.snapshot(spaceManager: spaceManager, displayUUID: displayUUID)
            .filter { $0.live.bundleID == bundleID }.count
    }

    private func waitForWindowCount(bundleID: String, atLeast count: Int,
                                    displayUUID: String,
                                    timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout, intervalNanoseconds: 300_000_000) {
            self.windowCount(bundleID: bundleID, displayUUID: displayUUID) >= count
        }
    }

    private func poll(timeout: TimeInterval,
                      intervalNanoseconds: UInt64 = 100_000_000,
                      _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return condition()
    }
}
