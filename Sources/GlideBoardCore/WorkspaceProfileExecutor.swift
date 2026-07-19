import AppKit

/// Applies a plan best-effort: one failed window never rolls back the others,
/// every rule reports its own outcome, and a retry re-runs single rules.
/// Placement travels an itinerary of real Space visits — windows are carried
/// by the gesture mover and framed through AX while their Space is active,
/// because AX cannot reach windows of inactive Spaces. The executor knows
/// services and protocols, never menu items.
@MainActor
final class WorkspaceProfileExecutor {
    private let spaceManager: SpaceManaging
    private let catalog: WorkspaceWindowCatalog
    private let launcher: WorkspaceApplicationLauncher
    private let recipes: WorkspaceWindowRecipeRegistry
    private let undoStore: WorkspaceUndoStore
    private let mover: WorkspaceWindowMover

    init(spaceManager: SpaceManaging, catalog: WorkspaceWindowCatalog,
         launcher: WorkspaceApplicationLauncher,
         recipes: WorkspaceWindowRecipeRegistry, undoStore: WorkspaceUndoStore,
         mover: WorkspaceWindowMover) {
        self.spaceManager = spaceManager
        self.catalog = catalog
        self.launcher = launcher
        self.recipes = recipes
        self.undoStore = undoStore
        self.mover = mover
    }

    struct PlacementJob {
        var label: String
        var windowID: UInt32
        var pid: pid_t
        var bundleID: String
        var appName: String
        var sourceOrdinal: Int?
        var targetOrdinal: Int
        var targetFrame: CGRect
        var needsUnminimize: Bool
        var minimizeAfterPlacement = false
        var stackingRank: Int
    }

    func apply(_ profile: WorkspaceProfile,
               limitToRuleIDs: Set<UUID>? = nil) async -> WorkspaceApplyReport {
        let startedAt = Date()
        var effective = profile
        if let limitToRuleIDs {
            effective.rules = profile.rules.filter { limitToRuleIDs.contains($0.id) }
        }
        WorkspaceLog.write("apply start: profile \"\(profile.name)\", "
            + "\(effective.rules.count) rules"
            + (limitToRuleIDs == nil ? "" : " (retry subset)"))

        func blockedReport(_ reason: String) -> WorkspaceApplyReport {
            WorkspaceLog.write("apply blocked: \(reason)")
            return WorkspaceApplyReport(
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
        let orderedSpaceIDs = spaceManager.orderedUserSpaceIDs(displayUUID: displayUUID)
        var spaceIDByOrdinal: [Int: UInt64] = [:]
        for (index, spaceID) in orderedSpaceIDs.enumerated() {
            spaceIDByOrdinal[index + 1] = spaceID
        }
        WorkspaceLog.write("apply: display ok, spaces by ordinal "
            + spaceIDByOrdinal.sorted { $0.key < $1.key }
                .map { "\($0.key)→\($0.value)" }.joined(separator: " ")
            + ", visible \(WorkspaceLog.describe(visibleFrame))")

        // Profiles restore POSITIONS: "Desktop 3" means the third desktop
        // left-to-right, the user's mental model. Reordering desktops moves
        // windows with them, so after a reorder the windows are misplaced
        // positionally and the apply moves them back. The captured UUIDs are
        // only the telltale that a reorder happened.
        let currentUUIDs = spaceManager.orderedUserSpaceUUIDs(displayUUID: displayUUID)
        let byIdentity = WorkspacePlanBuilder.resolveSpaceOrdinals(
            effective.rules, currentUUIDs: currentUUIDs)
        let reorderedSlots = zip(effective.rules, byIdentity)
            .filter { $0.spaceOrdinal != $1.spaceOrdinal }
            .map(\.0.slotName)
        var reorderDiagnostics: [String] = []
        if !reorderedSlots.isEmpty {
            reorderDiagnostics.append("The Desktops themselves were reordered since "
                + "this profile was captured; windows are being restored to the "
                + "captured left-to-right positions")
            WorkspaceLog.write("apply: desktops reordered since capture; "
                + "positional restore for \(reorderedSlots.count) rule(s)")
        }

        var firstPlan = true
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
            if firstPlan {
                firstPlan = false
                let managed = Set(effective.rules.map(\.bundleID))
                for entry in entries.map(\.live) where managed.contains(entry.bundleID) {
                    WorkspaceLog.write("live: win \(entry.cgWindowID) \(entry.bundleID)"
                        + " space=\(entry.spaceID.map(String.init) ?? "?")"
                        + "(ord \(entry.spaceOrdinal.map(String.init) ?? "?"))"
                        + " min=\(entry.isMinimized)"
                        + " \(WorkspaceLog.describe(entry.frame))")
                }
            }
            for rulePlan in plan.rulePlans {
                WorkspaceLog.write("plan \"\(rulePlan.rule.slotName)\""
                    + " space \(rulePlan.rule.spaceOrdinal): \(rulePlan.action)"
                    + " matched=\(rulePlan.matchedWindowID.map(String.init) ?? "-")"
                    + " needs(space=\(rulePlan.needsSpaceMove)"
                    + " frame=\(rulePlan.needsFrameChange)"
                    + " unmin=\(rulePlan.needsUnminimize))")
            }
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
                let appeared = await waitForWindowCount(
                    bundleID: bundleID, atLeast: 1,
                    displayUUID: displayUUID, timeout: 10)
                WorkspaceLog.write("launch \(bundleID): running, first window "
                    + (appeared ? "appeared" : "timed out"))
            case .failure(let reason):
                WorkspaceLog.write("launch \(bundleID): \(reason)")
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
                WorkspaceLog.write("create window: \(recipe.id) (have \(before))")
                guard await recipe.createWindow(app) else {
                    WorkspaceLog.write("create window: \(recipe.id) failed to trigger")
                    failureByRuleID[ruleID] = "The window recipe failed to trigger"
                    continue
                }
                if await waitForWindowCount(bundleID: bundleID, atLeast: before + 1,
                                            displayUUID: displayUUID, timeout: 8) {
                    WorkspaceLog.write("create window: \(recipe.id) appeared")
                    provenance[ruleID] = .created
                } else {
                    WorkspaceLog.write("create window: \(recipe.id) never appeared")
                    failureByRuleID[ruleID] = "The new window never appeared"
                }
            }
        }
        if !createRuleIDsByBundle.isEmpty {
            (plan, entriesByID) = planNow()
        }

        var jobs: [PlacementJob] = []
        var ruleIDByWindowID: [UInt32: UUID] = [:]
        for rulePlan in plan.rulePlans where rulePlan.action == .move {
            let rule = rulePlan.rule
            guard failureByRuleID[rule.id] == nil else { continue }
            guard let windowID = rulePlan.matchedWindowID,
                  let entry = entriesByID[windowID],
                  let targetFrame = rulePlan.targetFrame else {
                failureByRuleID[rule.id] = "The plan lost its window"
                continue
            }
            ruleIDByWindowID[windowID] = rule.id
            jobs.append(PlacementJob(label: rule.slotName,
                                     windowID: windowID,
                                     pid: entry.pid,
                                     bundleID: entry.live.bundleID,
                                     appName: entry.appName,
                                     sourceOrdinal: entry.live.spaceOrdinal,
                                     targetOrdinal: rule.spaceOrdinal,
                                     targetFrame: targetFrame,
                                     needsUnminimize: rulePlan.needsUnminimize,
                                     stackingRank: rule.stackingRank))
        }
        let placementFailures = await performPlacements(
            jobs, liveWindows: entriesByID.values.map(\.live),
            displayUUID: displayUUID, spaceIDs: orderedSpaceIDs,
            spaceUUIDs: currentUUIDs)
        for (windowID, failure) in placementFailures {
            if let ruleID = ruleIDByWindowID[windowID] {
                failureByRuleID[ruleID] = failure
            }
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
                results.append(WorkspaceRuleResult(rule: rule,
                                                   outcome: success(afterMove: true)))
            case .launchAndAdopt:
                results.append(WorkspaceRuleResult(
                    rule: rule, outcome: .failed("No window appeared after launching")))
            case .createWindow:
                results.append(WorkspaceRuleResult(
                    rule: rule, outcome: .failed("No window was created for this slot")))
            }
        }

        var diagnostics = reorderDiagnostics + plan.diagnostics
        diagnostics.append(contentsOf: DisplayConfigurationResolver
            .currentPrerequisiteIssues())
        let report = WorkspaceApplyReport(profileID: profile.id,
                                          profileName: profile.name,
                                          results: results,
                                          extraWindows: plan.extraWindows,
                                          diagnostics: diagnostics,
                                          finishedAt: Date())
        for result in results {
            WorkspaceLog.write("result \"\(result.rule.slotName)\": \(result.outcome.label)")
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        WorkspaceLog.write("apply done in \(elapsed)ms: \(report.headline)")
        return report
    }

    func undoLastApply() async -> [String] {
        guard let snapshot = undoStore.latest else { return ["Nothing to undo"] }
        WorkspaceLog.write("undo start: \(snapshot.windows.count) windows "
            + "from \"\(snapshot.profileName)\"")
        let current = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        guard let displayUUID = current.displays.first(where: \.isPrimary)?.uuid
            ?? current.displays.first?.uuid else { return ["No display detected"] }
        let spaceIDs = spaceManager.orderedUserSpaceIDs(displayUUID: displayUUID)
        let entries = catalog.snapshot(spaceManager: spaceManager,
                                       displayUUID: displayUUID)
        let byID = Dictionary(entries.map { ($0.live.cgWindowID, $0) },
                              uniquingKeysWith: { first, _ in first })

        var lines: [String] = []
        var jobs: [PlacementJob] = []
        var labelByWindowID: [UInt32: String] = [:]
        for state in snapshot.windows {
            guard let entry = byID[state.cgWindowID] else {
                lines.append("\(state.slotName): the window no longer exists")
                continue
            }
            let targetOrdinal: Int
            if let spaceID = state.spaceID, let index = spaceIDs.firstIndex(of: spaceID) {
                targetOrdinal = index + 1
            } else if let ordinal = entry.live.spaceOrdinal {
                lines.append("\(state.slotName): its original Space is gone; "
                    + "only the frame was restored")
                targetOrdinal = ordinal
            } else {
                lines.append("\(state.slotName): not reachable on any Space")
                continue
            }
            labelByWindowID[state.cgWindowID] = state.slotName
            jobs.append(PlacementJob(label: state.slotName,
                                     windowID: state.cgWindowID,
                                     pid: entry.pid,
                                     bundleID: entry.live.bundleID,
                                     appName: entry.appName,
                                     sourceOrdinal: entry.live.spaceOrdinal,
                                     targetOrdinal: targetOrdinal,
                                     targetFrame: state.frame,
                                     needsUnminimize: entry.live.isMinimized
                                         && !state.wasMinimized,
                                     minimizeAfterPlacement: state.wasMinimized,
                                     stackingRank: state.stackingRank))
        }
        let failures = await performPlacements(
            jobs, liveWindows: byID.values.map(\.live),
            displayUUID: displayUUID, spaceIDs: spaceIDs,
            spaceUUIDs: spaceManager.orderedUserSpaceUUIDs(displayUUID: displayUUID))
        for job in jobs {
            if let failure = failures[job.windowID] {
                lines.append("\(job.label): \(failure)")
            } else {
                lines.append("\(job.label): restored")
            }
        }
        undoStore.clear()
        WorkspaceLog.write("undo done: \(lines.joined(separator: "; "))")
        return lines
    }

    // MARK: - Placement itinerary

    private func performPlacements(_ jobs: [PlacementJob],
                                   liveWindows: [WorkspaceLiveWindow],
                                   displayUUID: String,
                                   spaceIDs: [UInt64],
                                   spaceUUIDs: [String]) async -> [UInt32: String] {
        guard !jobs.isEmpty else { return [:] }
        var failures: [UInt32: String] = [:]
        let originSpace = spaceManager.currentSpaceID(displayUUID: displayUUID)
        let originApp = NSWorkspace.shared.frontmostApplication
        let originCursor = CGEvent(source: nil)?.location

        func ordinal(of spaceID: UInt64?) -> Int? {
            spaceID.flatMap { spaceIDs.firstIndex(of: $0) }.map { $0 + 1 }
        }

        // Phase 1 — whole-app moves ride the Dock's Assign To command: one
        // visit per target Space, one menu press per app, frames set there.
        let moveJobs = jobs.filter { $0.sourceOrdinal != $0.targetOrdinal }
        let candidatePlan = WorkspacePlanBuilder.dockAssignPlan(
            jobs: moveJobs.map { ($0.bundleID, $0.windowID, $0.targetOrdinal,
                                  $0.needsUnminimize) },
            liveWindows: liveWindows)
        // The Dock pin state decides upfront: unpinned apps get assigned and
        // unpinned again; apps the user pinned to exactly the target Space
        // get gathered without touching the pin; pins to any other Desktop
        // mean dragging, with no wasted Space visit.
        var assignPlan: [String: Int] = [:]
        for (bundleID, target) in candidatePlan {
            let binding = mover.dockAssignment(bundleID: bundleID)
            let targetUUID = spaceUUIDs.indices.contains(target - 1)
                ? spaceUUIDs[target - 1] : ""
            if binding == nil || (binding == targetUUID && !targetUUID.isEmpty) {
                assignPlan[bundleID] = target
            } else {
                WorkspaceLog.write("assign \(bundleID): pinned to another Desktop; "
                    + "it will be dragged")
            }
        }
        var completed = Set<UInt32>()
        if !assignPlan.isEmpty {
            WorkspaceLog.write("assign plan: "
                + assignPlan.sorted { $0.key < $1.key }
                    .map { "\($0.key)→Space \($0.value)" }.joined(separator: ", "))
            var bundlesByTarget: [Int: [String]] = [:]
            for (bundleID, target) in assignPlan {
                bundlesByTarget[target, default: []].append(bundleID)
            }
            for (targetOrdinal, bundles) in bundlesByTarget.sorted(by: { $0.key < $1.key }) {
                guard await mover.switchToOrdinal(targetOrdinal,
                                                  displayUUID: displayUUID,
                                                  spaceIDs: spaceIDs) else { continue }
                for bundleID in bundles.sorted() {
                    let bundleJobs = moveJobs.filter { $0.bundleID == bundleID }
                    guard let appName = bundleJobs.first?.appName else { continue }
                    if let failure = await mover.assignAppToCurrentSpace(
                        appName: appName, bundleID: bundleID,
                        jobWindowIDs: bundleJobs.map(\.windowID),
                        displayUUID: displayUUID) {
                        WorkspaceLog.write("assign \(appName): \(failure); "
                            + "falling back to dragging")
                        continue
                    }
                    for var job in bundleJobs {
                        job.sourceOrdinal = job.targetOrdinal
                        if let failure = await perform(job, displayUUID: displayUUID,
                                                       spaceIDs: spaceIDs) {
                            failures[job.windowID] = failure
                            WorkspaceLog.write("place \"\(job.label)\": \(failure)")
                        } else {
                            WorkspaceLog.write("place \"\(job.label)\": ok (assigned)")
                        }
                        completed.insert(job.windowID)
                    }
                }
            }
        }

        // Phase 2 — everything else travels the drag itinerary.
        var pending = jobs.filter { !completed.contains($0.windowID) }
        var stalls = 0
        while !pending.isEmpty && stalls < jobs.count * 2 + 4 {
            stalls += 1
            let cursor = ordinal(of: spaceManager
                .currentSpaceID(displayUUID: displayUUID)) ?? 1
            let order = WorkspacePlanBuilder.placementOrder(
                jobs: pending.map { ($0.sourceOrdinal, $0.targetOrdinal) },
                startingAt: cursor)
            guard let index = order.first else { break }
            let job = pending.remove(at: index)
            if let failure = await perform(job, displayUUID: displayUUID,
                                           spaceIDs: spaceIDs) {
                failures[job.windowID] = failure
                WorkspaceLog.write("place \"\(job.label)\": \(failure)")
            } else {
                WorkspaceLog.write("place \"\(job.label)\": ok")
            }
        }
        for job in pending {
            failures[job.windowID] = "Skipped: the placement loop stalled"
        }

        await restoreStacking(jobs: jobs, failures: failures,
                              displayUUID: displayUUID, spaceIDs: spaceIDs)

        if let originOrdinal = ordinal(of: originSpace) {
            _ = await mover.switchToOrdinal(originOrdinal, displayUUID: displayUUID,
                                            spaceIDs: spaceIDs)
        }
        originApp?.activate()
        if let originCursor {
            CGWarpMouseCursorPosition(originCursor)
        }
        return failures
    }

    private func perform(_ job: PlacementJob, displayUUID: String,
                         spaceIDs: [UInt64]) async -> String? {
        WorkspaceLog.write("place \"\(job.label)\" win \(job.windowID): "
            + "space \(job.sourceOrdinal.map(String.init) ?? "?") -> "
            + "\(job.targetOrdinal), frame \(WorkspaceLog.describe(job.targetFrame))")
        var sourceOrdinal = job.sourceOrdinal
        if job.needsUnminimize {
            guard let axWindow = await axWindowPolled(job.windowID, pid: job.pid) else {
                return "The minimized window is not reachable through AX"
            }
            axWindow.setMinimized(false)
            guard await poll(timeout: 3, { !axWindow.isMinimized() }) else {
                return "Could not unminimize the window"
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            sourceOrdinal = spaceManager.spaceID(ofWindow: job.windowID)
                .flatMap { spaceIDs.firstIndex(of: $0) }.map { $0 + 1 }
        }
        guard let sourceOrdinal else {
            return "The window is not on any Space"
        }
        guard await mover.switchToOrdinal(sourceOrdinal, displayUUID: displayUUID,
                                          spaceIDs: spaceIDs) else {
            return "Could not switch to Space \(sourceOrdinal)"
        }
        if sourceOrdinal != job.targetOrdinal {
            if let failure = await mover.carryWindow(job.windowID, pid: job.pid,
                                                     toOrdinal: job.targetOrdinal,
                                                     displayUUID: displayUUID,
                                                     spaceIDs: spaceIDs) {
                return failure
            }
        }
        guard let axWindow = await axWindowPolled(job.windowID, pid: job.pid) else {
            return "The window is not reachable through AX on Space \(job.targetOrdinal)"
        }
        let inPlace = axWindow.frame().map {
            WorkspaceGeometry.approximatelyEqual($0, job.targetFrame, tolerance: 4)
        } ?? false
        if !inPlace {
            axWindow.setFrame(job.targetFrame)
            let accepted = await poll(timeout: 3) {
                axWindow.frame().map {
                    WorkspaceGeometry.approximatelyEqual($0, job.targetFrame, tolerance: 4)
                } ?? false
            }
            guard accepted else {
                let got = axWindow.frame().map { WorkspaceLog.describe($0) }
                    ?? "an unreadable frame"
                return "The window refused its frame; it reports \(got)"
            }
        }
        if job.minimizeAfterPlacement {
            axWindow.setMinimized(true)
        }
        return nil
    }

    /// Best effort, visiting each multi-window Space: windows are raised
    /// back-to-front so the captured front window is raised last.
    private func restoreStacking(jobs: [PlacementJob], failures: [UInt32: String],
                                 displayUUID: String, spaceIDs: [UInt64]) async {
        let placed = jobs.filter { failures[$0.windowID] == nil }
        for (ordinal, group) in Dictionary(grouping: placed, by: \.targetOrdinal)
            .sorted(by: { $0.key < $1.key }) where group.count > 1 {
            guard await mover.switchToOrdinal(ordinal, displayUUID: displayUUID,
                                              spaceIDs: spaceIDs) else { continue }
            for job in group.sorted(by: { $0.stackingRank > $1.stackingRank }) {
                catalog.axWindow(for: job.windowID, pid: job.pid)?.raise()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    // MARK: - Support

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

    /// An app's AX window list refreshes up to a second after a Space
    /// switch; poll instead of trusting the first read.
    private func axWindowPolled(_ windowID: UInt32,
                                pid: pid_t) async -> WorkspaceAXWindow? {
        var lookup: WorkspaceAXWindow?
        _ = await poll(timeout: 2.5) {
            lookup = self.catalog.axWindow(for: windowID, pid: pid)
            return lookup != nil
        }
        return lookup
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
