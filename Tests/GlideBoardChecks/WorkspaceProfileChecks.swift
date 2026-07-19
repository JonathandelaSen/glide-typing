import AppKit
@testable import GlideBoardCore

private func makeDisplay(uuid: String = "D-1", primary: Bool = true,
                         origin: CGPoint = .zero,
                         size: CGSize = CGSize(width: 1728, height: 1117),
                         spaces: Int = 6) -> DisplaySignature {
    DisplaySignature(uuid: uuid, localizedName: "Built-in",
                     vendorNumber: 1552, modelNumber: 41058, serialNumber: 0,
                     frame: CGRect(origin: origin, size: size),
                     visibleFrame: CGRect(x: origin.x, y: origin.y + 25,
                                          width: size.width, height: size.height - 25),
                     rotationDegrees: 0, isPrimary: primary, userSpaceCount: spaces)
}

private func makeConfiguration(_ displays: [DisplaySignature] = [makeDisplay()])
    -> DisplayConfigurationSignature {
    DisplayConfigurationSignature(displays: displays, screensHaveSeparateSpaces: false)
}

private func makeRule(bundleID: String, slot: String, space: Int, rank: Int = 0,
                      frame: NormalizedRect = NormalizedRect(x: 0.1, y: 0.1,
                                                             width: 0.5, height: 0.5),
                      excluded: Bool = false) -> WorkspaceWindowRule {
    WorkspaceWindowRule(id: UUID(), bundleID: bundleID, slotName: slot,
                        displayUUID: "D-1", spaceOrdinal: space, frame: frame,
                        stackingRank: rank, axRoleHint: "AXWindow",
                        axSubroleHint: "AXStandardWindow", titleHint: nil,
                        recipeID: nil, isExcluded: excluded)
}

private func makeProfile(rules: [WorkspaceWindowRule]) -> WorkspaceProfile {
    WorkspaceProfile(id: UUID(), name: "Work", display: makeConfiguration(),
                     rules: rules, createdAt: Date(), updatedAt: Date())
}

private func makeWindow(id: UInt32, bundleID: String, frame: CGRect,
                        space: UInt64? = 501, ordinal: Int? = 1,
                        minimized: Bool = false) -> WorkspaceLiveWindow {
    WorkspaceLiveWindow(cgWindowID: id, bundleID: bundleID, frame: frame,
                        spaceID: space, spaceOrdinal: ordinal,
                        isMinimized: minimized, title: nil,
                        role: "AXWindow", subrole: "AXStandardWindow")
}

private let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)

private func makeInput(profile: WorkspaceProfile,
                       windows: [WorkspaceLiveWindow],
                       running: Set<String>,
                       spaces: [Int: UInt64] = [1: 501, 2: 502, 3: 503,
                                                4: 504, 5: 505, 6: 506],
                       recipes: Set<String> = ["com.brave.Browser"]) -> WorkspacePlanInput {
    WorkspacePlanInput(profile: profile, liveWindows: windows,
                       runningBundleIDs: running, spaceIDByOrdinal: spaces,
                       visibleFrame: visible, creationRecipeBundleIDs: recipes)
}

@MainActor
func workspaceProfileChecks() async {
    Checks.shared.begin("Workspace geometry and display signatures")

    await Checks.shared.test("AppKit frames convert to top-left CG space") {
        let appKit = CGRect(x: 100, y: 200, width: 600, height: 400)
        let cg = WorkspaceGeometry.cgRect(fromAppKit: appKit, primaryHeight: 1117)
        try expectEqual(cg, CGRect(x: 100, y: 1117 - 600, width: 600, height: 400))
    }

    await Checks.shared.test("normalize/denormalize round-trips inside a display") {
        let container = CGRect(x: 0, y: 25, width: 1728, height: 1092)
        let frame = CGRect(x: 120, y: 60, width: 900, height: 700)
        let normalized = WorkspaceGeometry.normalize(frame, in: container)
        let restored = WorkspaceGeometry.denormalize(normalized, in: container)
        try expectTrue(WorkspaceGeometry.approximatelyEqual(frame, restored, tolerance: 1),
                       "expected \(frame), got \(restored)")
    }

    await Checks.shared.test("a zero-sized container normalizes to zero, not NaN") {
        let normalized = WorkspaceGeometry.normalize(CGRect(x: 1, y: 2, width: 3, height: 4),
                                                     in: .zero)
        try expectEqual(normalized, NormalizedRect(x: 0, y: 0, width: 0, height: 0))
    }

    await Checks.shared.test("an unchanged display setup has no mismatch reasons") {
        let saved = makeConfiguration()
        try expectEqual(DisplayConfigurationResolver.mismatchReasons(saved: saved,
                                                                     current: saved), [])
    }

    await Checks.shared.test("resolution, count and arrangement changes are named") {
        let saved = makeConfiguration()
        let resized = makeConfiguration([makeDisplay(size: CGSize(width: 1512, height: 982))])
        let resizedReasons = DisplayConfigurationResolver.mismatchReasons(
            saved: saved, current: resized)
        try expectTrue(resizedReasons.contains { $0.contains("resolution") },
                       "missing resolution reason in \(resizedReasons)")

        let twoDisplays = makeConfiguration([
            makeDisplay(), makeDisplay(uuid: "D-2", primary: false,
                                       origin: CGPoint(x: 1728, y: 0)),
        ])
        let countReasons = DisplayConfigurationResolver.mismatchReasons(
            saved: saved, current: twoDisplays)
        try expectEqual(countReasons.count, 1)
        try expectTrue(countReasons[0].contains("1 display"), countReasons[0])

        var moved = makeDisplay()
        moved.frame.origin = CGPoint(x: 0, y: 100)
        let arrangementReasons = DisplayConfigurationResolver.mismatchReasons(
            saved: saved, current: makeConfiguration([moved]))
        try expectTrue(arrangementReasons.contains { $0.contains("arrangement") },
                       "missing arrangement reason in \(arrangementReasons)")
    }

    await Checks.shared.test("same display count with different hardware never matches") {
        let saved = makeConfiguration()
        var other = makeDisplay()
        other.serialNumber = 99
        let reasons = DisplayConfigurationResolver.mismatchReasons(
            saved: saved, current: makeConfiguration([other]))
        try expectTrue(reasons.contains { $0.contains("different physical display") },
                       String(describing: reasons))
    }

    await Checks.shared.test("display mapping pairs saved and current UUIDs") {
        let saved = makeConfiguration()
        var current = makeDisplay()
        current.uuid = "D-NEW"
        let mapping = DisplayConfigurationResolver.displayUUIDMapping(
            saved: saved, current: makeConfiguration([current]))
        try expectEqual(mapping, ["D-1": "D-NEW"])
    }

    await Checks.shared.test("prerequisites report reordering and separate Spaces") {
        let issues = DisplayConfigurationResolver.prerequisiteIssues(
            automaticSpaceReorderingEnabled: true, displayCount: 2,
            screensHaveSeparateSpaces: false)
        try expectEqual(issues.count, 2)
        try expectTrue(issues[0].contains("Automatically rearrange"), issues[0])
        try expectEqual(DisplayConfigurationResolver.prerequisiteIssues(
            automaticSpaceReorderingEnabled: false, displayCount: 1,
            screensHaveSeparateSpaces: false), [])
    }

    Checks.shared.begin("Workspace profile store")

    await Checks.shared.test("profiles round-trip through the JSON store") {
        let directory = temporaryDirectory()
        let store = WorkspaceProfileStore(directory: directory)
        let profile = makeProfile(rules: [makeRule(bundleID: "com.apple.finder",
                                                   slot: "Finder", space: 6)])
        try expectTrue(store.save(profile), "save failed")

        let reloaded = WorkspaceProfileStore(directory: directory)
        try expectEqual(reloaded.profiles.count, 1)
        let loaded = try unwrap(reloaded.profile(id: profile.id))
        try expectEqual(loaded.name, "Work")
        try expectEqual(loaded.rules, profile.rules)
        try expectEqual(loaded.display, profile.display)
    }

    await Checks.shared.test("rename and delete persist and validate input") {
        let directory = temporaryDirectory()
        let store = WorkspaceProfileStore(directory: directory)
        let profile = makeProfile(rules: [])
        _ = store.save(profile)
        try expectFalse(store.rename(id: profile.id, to: "   "),
                        "blank names must be rejected")
        try expectTrue(store.rename(id: profile.id, to: "Browsing"))
        try expectEqual(WorkspaceProfileStore(directory: directory)
            .profile(id: profile.id)?.name, "Browsing")
        try expectTrue(store.delete(id: profile.id))
        try expectFalse(store.delete(id: profile.id), "double delete must report false")
        try expectEqual(WorkspaceProfileStore(directory: directory).profiles.count, 0)
    }

    await Checks.shared.test("a newer schema or corrupt file refuses to load and save") {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("workspace_profiles.json")
        try Data(#"{"schemaVersion": 99, "profiles": []}"#.utf8).write(to: url)
        let newer = WorkspaceProfileStore(directory: directory)
        try expectTrue(newer.loadFailure?.contains("schema 99") == true,
                       String(describing: newer.loadFailure))
        try expectFalse(newer.save(makeProfile(rules: [])),
                        "saving over a newer schema must be refused")

        try Data("not json".utf8).write(to: url)
        let corrupt = WorkspaceProfileStore(directory: directory)
        try expectTrue(corrupt.loadFailure != nil, "corrupt file must surface a reason")
    }

    Checks.shared.begin("Workspace plan builder")

    await Checks.shared.test("a satisfied layout plans no work (idempotent reapply)") {
        let rule = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 1)
        let profile = makeProfile(rules: [rule])
        let target = WorkspaceGeometry.denormalize(rule.frame, in: visible)
        let window = makeWindow(id: 10, bundleID: "com.spotify.client", frame: target)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: profile, windows: [window], running: ["com.spotify.client"]))
        try expectEqual(plan.rulePlans.count, 1)
        try expectEqual(plan.rulePlans[0].action, .none)
        try expectEqual(plan.rulePlans[0].matchedWindowID, 10)
        try expectFalse(plan.needsLaunchOrCreate)
        try expectEqual(plan.extraWindows, [])
    }

    await Checks.shared.test("a displaced window plans a move with the exact needs") {
        let rule = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 2)
        let profile = makeProfile(rules: [rule])
        let window = makeWindow(id: 10, bundleID: "com.spotify.client",
                                frame: CGRect(x: 700, y: 300, width: 400, height: 300),
                                space: 501, ordinal: 1)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: profile, windows: [window], running: ["com.spotify.client"]))
        let rulePlan = plan.rulePlans[0]
        try expectEqual(rulePlan.action, .move)
        try expectTrue(rulePlan.needsSpaceMove, "window sits on space 1, rule wants 2")
        try expectTrue(rulePlan.needsFrameChange)
        try expectEqual(rulePlan.targetSpaceID, 502)
    }

    await Checks.shared.test("a minimized required window plans an unminimize") {
        let rule = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 1)
        let target = WorkspaceGeometry.denormalize(rule.frame, in: visible)
        let window = makeWindow(id: 10, bundleID: "com.spotify.client", frame: target,
                                space: nil, ordinal: nil, minimized: true)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [rule]), windows: [window],
            running: ["com.spotify.client"]))
        try expectEqual(plan.rulePlans[0].action, .move)
        try expectTrue(plan.rulePlans[0].needsUnminimize)
        try expectTrue(plan.rulePlans[0].needsSpaceMove,
                       "minimized windows report no space, so the move is planned")
    }

    await Checks.shared.test("Brave slots reconcile by geometry, never by title") {
        let left = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
        let right = NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
        let ruleA = makeRule(bundleID: "com.brave.Browser", slot: "Brave A",
                             space: 4, frame: left)
        let ruleB = makeRule(bundleID: "com.brave.Browser", slot: "Brave B",
                             space: 5, frame: right)
        var windowOnFour = makeWindow(
            id: 31, bundleID: "com.brave.Browser",
            frame: WorkspaceGeometry.denormalize(right, in: visible),
            space: 504, ordinal: 4)
        windowOnFour.title = "completely mutable tab title"
        var windowOnFive = makeWindow(
            id: 30, bundleID: "com.brave.Browser",
            frame: WorkspaceGeometry.denormalize(left, in: visible),
            space: 505, ordinal: 5)
        windowOnFive.title = "another tab"
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [ruleA, ruleB]),
            windows: [windowOnFour, windowOnFive],
            running: ["com.brave.Browser"]))
        try expectEqual(plan.rulePlans[0].matchedWindowID, 31,
                        "Brave A takes the space-4 window despite its frame")
        try expectEqual(plan.rulePlans[1].matchedWindowID, 30)
        try expectEqual(plan.rulePlans[0].action, .move)
        try expectEqual(plan.rulePlans[1].action, .move)
    }

    await Checks.shared.test("one window never satisfies two rules; the second creates") {
        let ruleA = makeRule(bundleID: "com.brave.Browser", slot: "Brave A", space: 4)
        let ruleB = makeRule(bundleID: "com.brave.Browser", slot: "Brave B", space: 5)
        let window = makeWindow(id: 30, bundleID: "com.brave.Browser",
                                frame: CGRect(x: 0, y: 25, width: 800, height: 600),
                                space: 504, ordinal: 4)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [ruleA, ruleB]), windows: [window],
            running: ["com.brave.Browser"]))
        try expectEqual(plan.rulePlans[0].matchedWindowID, 30)
        try expectEqual(plan.rulePlans[1].action, .createWindow)
        try expectNil(plan.rulePlans[1].matchedWindowID)
    }

    await Checks.shared.test("a quit app plans launch; no recipe means blocked, not ⌘N") {
        let spotify = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 1)
        let unknown = makeRule(bundleID: "com.example.tool", slot: "Tool", space: 2)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [spotify, unknown]), windows: [],
            running: ["com.example.tool"]))
        try expectEqual(plan.rulePlans[0].action, .launchAndAdopt)
        guard case .blocked(let reason) = plan.rulePlans[1].action else {
            throw CheckFailure(message: "expected blocked, got \(plan.rulePlans[1].action)",
                               location: "workspace")
        }
        try expectTrue(reason.contains("no tested window-creation recipe"), reason)
    }

    await Checks.shared.test("a missing Space blocks the rule and never creates Spaces") {
        let rule = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 9)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [rule]), windows: [],
            running: ["com.spotify.client"]))
        guard case .blocked(let reason) = plan.rulePlans[0].action else {
            throw CheckFailure(message: "expected blocked, got \(plan.rulePlans[0].action)",
                               location: "workspace")
        }
        try expectTrue(reason.contains("never creates Spaces"), reason)
    }

    await Checks.shared.test("unmatched windows of managed apps are reported as extras") {
        let rule = makeRule(bundleID: "com.brave.Browser", slot: "Brave A", space: 4)
        let target = WorkspaceGeometry.denormalize(rule.frame, in: visible)
        let matched = makeWindow(id: 30, bundleID: "com.brave.Browser", frame: target,
                                 space: 504, ordinal: 4)
        let extraBrave = makeWindow(id: 31, bundleID: "com.brave.Browser",
                                    frame: CGRect(x: 5, y: 30, width: 300, height: 200),
                                    space: 501, ordinal: 1)
        let unrelated = makeWindow(id: 40, bundleID: "com.apple.TextEdit",
                                   frame: CGRect(x: 5, y: 30, width: 300, height: 200))
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [rule]),
            windows: [matched, extraBrave, unrelated],
            running: ["com.brave.Browser"]))
        try expectEqual(plan.extraWindows.map(\.cgWindowID), [31],
                        "extras are unmatched windows of managed apps only")
    }

    await Checks.shared.test("excluded rules are skipped entirely") {
        let rule = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 1,
                            excluded: true)
        let plan = WorkspacePlanBuilder.build(makeInput(
            profile: makeProfile(rules: [rule]), windows: [], running: []))
        try expectEqual(plan.rulePlans, [])
        try expectTrue(plan.diagnostics.contains { $0.contains("no active window rules") },
                       String(describing: plan.diagnostics))
    }

    await Checks.shared.test("planning is deterministic for the same state") {
        let ruleA = makeRule(bundleID: "com.brave.Browser", slot: "Brave A", space: 4)
        let ruleB = makeRule(bundleID: "com.brave.Browser", slot: "Brave B", space: 4)
        let windows = [
            makeWindow(id: 32, bundleID: "com.brave.Browser",
                       frame: CGRect(x: 0, y: 25, width: 800, height: 600),
                       space: 504, ordinal: 4),
            makeWindow(id: 31, bundleID: "com.brave.Browser",
                       frame: CGRect(x: 0, y: 25, width: 800, height: 600),
                       space: 504, ordinal: 4),
        ]
        let input = makeInput(profile: makeProfile(rules: [ruleA, ruleB]),
                              windows: windows, running: ["com.brave.Browser"])
        let first = WorkspacePlanBuilder.build(input)
        let second = WorkspacePlanBuilder.build(input)
        try expectEqual(first, second)
        try expectEqual(first.rulePlans[0].matchedWindowID, 31,
                        "equal costs break ties by the lower window ID")
    }

    Checks.shared.begin("Workspace apply reporting and undo")

    await Checks.shared.test("the report headline aggregates best-effort results") {
        let rule = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 1)
        let report = WorkspaceApplyReport(
            profileID: UUID(), profileName: "Work",
            results: [
                WorkspaceRuleResult(rule: rule, outcome: .applied),
                WorkspaceRuleResult(rule: rule, outcome: .applied),
                WorkspaceRuleResult(rule: rule, outcome: .satisfied),
                WorkspaceRuleResult(rule: rule, outcome: .launched),
                WorkspaceRuleResult(rule: rule, outcome: .failed("timeout")),
            ],
            extraWindows: [makeWindow(id: 9, bundleID: "com.spotify.client",
                                      frame: .zero)],
            diagnostics: [], finishedAt: Date())
        try expectEqual(report.headline,
                        "2 windows placed, 1 already in place, 1 app launched, "
                        + "1 failed, 1 extra window untouched")
        try expectEqual(report.failedRules.count, 1)
        try expectEqual(WorkspaceApplyReport(profileID: UUID(), profileName: "Empty",
                                             results: [], extraWindows: [],
                                             diagnostics: [], finishedAt: Date()).headline,
                        "Nothing to do")
    }

    await Checks.shared.test("the undo store keeps exactly the latest snapshot") {
        let store = WorkspaceUndoStore()
        try expectNil(store.latest)
        let first = WorkspaceUndoSnapshot(profileName: "Work", takenAt: Date(),
                                          windows: [])
        store.replace(first)
        try expectEqual(store.latest?.profileName, "Work")
        let second = WorkspaceUndoSnapshot(profileName: "Browsing", takenAt: Date(),
                                           windows: [])
        store.replace(second)
        try expectEqual(store.latest?.profileName, "Browsing")
        store.clear()
        try expectNil(store.latest)
    }

    await Checks.shared.test("capture keeps one entry per window on its own Space only") {
        func candidate(_ id: UInt32, _ bundle: String, ordinal: Int?,
                       minimized: Bool = false) -> WorkspaceCaptureService.CaptureCandidate {
            WorkspaceCaptureService.CaptureCandidate(
                cgWindowID: id, bundleID: bundle, appName: bundle,
                spaceOrdinal: ordinal, isMinimized: minimized,
                frame: CGRect(x: 0, y: 25, width: 800, height: 600),
                title: nil, subrole: "AXStandardWindow")
        }
        let captured = WorkspaceCaptureService.capturedWindows(
            from: [
                candidate(10, "com.spotify.client", ordinal: 5),
                candidate(10, "com.spotify.client", ordinal: 5),
                candidate(11, "com.apple.finder", ordinal: nil),
                candidate(12, "com.openai.codex", ordinal: 3, minimized: true),
                candidate(13, "com.anthropic.claudefordesktop", ordinal: 3),
                candidate(14, "com.openai.codex", ordinal: 3),
            ],
            globalOrderFrontToBack: [10, 14, 13, 11])
        try expectEqual(captured.map(\.cgWindowID), [14, 13, 10],
                        "spaceless (11), minimized (12) and duplicate entries drop; "
                        + "sorted by Space, then global front-to-back order")
        try expectEqual(captured.map(\.stackingRank), [0, 1, 0],
                        "ranks per Space follow the global front-to-back order")
    }

    await Checks.shared.test("a Space's phantom repeats cannot survive capture shaping") {
        // The v36 incident: one Space's windows reported on-screen for every
        // visited Space. With per-window Space assignment each window appears
        // exactly once, on its own Space.
        let trio = (1...3).map { id in
            WorkspaceCaptureService.CaptureCandidate(
                cgWindowID: UInt32(id), bundleID: "app\(id)", appName: "App \(id)",
                spaceOrdinal: 7, isMinimized: false,
                frame: CGRect(x: 0, y: 25, width: 800, height: 600),
                title: nil, subrole: "AXStandardWindow")
        }
        let captured = WorkspaceCaptureService.capturedWindows(
            from: trio + trio + trio, globalOrderFrontToBack: [1, 2, 3])
        try expectEqual(captured.count, 3)
        try expectEqual(Set(captured.map(\.spaceOrdinal)), [7])
    }

    await Checks.shared.test("captured windows become lettered slots and hint-only titles") {
        let display = makeDisplay()
        let captured = [
            WorkspaceCaptureService.CapturedWindow(
                cgWindowID: 51, bundleID: "com.brave.Browser", appName: "Brave Browser",
                spaceOrdinal: 5, stackingRank: 0,
                frame: CGRect(x: 0, y: 50, width: 800, height: 600),
                title: "Some tab", subrole: "AXStandardWindow"),
            WorkspaceCaptureService.CapturedWindow(
                cgWindowID: 50, bundleID: "com.brave.Browser", appName: "Brave Browser",
                spaceOrdinal: 4, stackingRank: 0,
                frame: CGRect(x: 0, y: 50, width: 800, height: 600),
                title: "Another tab", subrole: "AXStandardWindow"),
            WorkspaceCaptureService.CapturedWindow(
                cgWindowID: 10, bundleID: "com.spotify.client", appName: "Spotify",
                spaceOrdinal: 1, stackingRank: 1,
                frame: CGRect(x: 100, y: 100, width: 900, height: 700),
                title: nil, subrole: "AXStandardWindow"),
        ]
        let rules = WorkspaceCaptureService.rules(
            from: captured, display: display,
            spaceUUIDs: ["U1", "U2", "U3", "U4", "", "U6"],
            recipeIDByBundle: ["com.brave.Browser": "brave-new-window"])
        try expectEqual(rules.map(\.slotName), ["Spotify", "Brave Browser A",
                                                "Brave Browser B"],
                        "rules sort by Space and letter multi-window apps in order")
        try expectEqual(rules[1].spaceOrdinal, 4)
        try expectEqual(rules[0].spaceUUID, "U1")
        try expectEqual(rules[1].spaceUUID, "U4")
        try expectNil(rules[2].spaceUUID, "an empty Space UUID is stored as nil")
        try expectEqual(rules[1].recipeID, "brave-new-window")
        try expectEqual(rules[1].titleHint, "Another tab")
        try expectNil(rules[0].recipeID)
        let restored = WorkspaceGeometry.denormalize(rules[0].frame,
                                                     in: display.visibleFrame)
        try expectTrue(WorkspaceGeometry.approximatelyEqual(
            restored, CGRect(x: 100, y: 100, width: 900, height: 700), tolerance: 1),
            "frames normalize against the display's visible frame")
    }

    await Checks.shared.test("promoting a rule to front renumbers only its Space") {
        let front = makeRule(bundleID: "com.openai.codex", slot: "ChatGPT", space: 3,
                             rank: 0)
        let middle = makeRule(bundleID: "com.anthropic.claudefordesktop",
                              slot: "Claude", space: 3, rank: 1)
        let back = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 3,
                            rank: 2)
        let elsewhere = makeRule(bundleID: "com.apple.finder", slot: "Finder",
                                 space: 6, rank: 0)
        var profile = makeProfile(rules: [front, middle, back, elsewhere])
        profile.promoteRuleToFront(back.id)
        let ranks = Dictionary(uniqueKeysWithValues: profile.rules.map {
            ($0.slotName, $0.stackingRank)
        })
        try expectEqual(ranks["Spotify"], 0)
        try expectEqual(ranks["ChatGPT"], 1, "previous order is preserved behind the front")
        try expectEqual(ranks["Claude"], 2)
        try expectEqual(ranks["Finder"], 0, "other Spaces are untouched")
    }

    await Checks.shared.test("capture summaries list Spaces with their slots in order") {
        let rules = [
            makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 1, rank: 0),
            makeRule(bundleID: "dev.kdrag0n.MacVirt", slot: "OrbStack", space: 1, rank: 1),
            makeRule(bundleID: "com.apple.finder", slot: "Finder", space: 6, rank: 0),
        ]
        let lines = WorkspaceCaptureService.summaryLines(
            profile: makeProfile(rules: rules), spaceCount: 6)
        try expectEqual(lines.count, 3)
        try expectTrue(lines[0].contains("6 Spaces"), lines[0])
        try expectEqual(lines[1], "Space 1: Spotify, OrbStack")
        try expectEqual(lines[2], "Space 6: Finder")
    }

    await Checks.shared.test("placement order consumes the current Space first") {
        let jobs: [(source: Int?, target: Int)] = [
            (source: 3, target: 1), (source: 3, target: 3), (source: 1, target: 1),
            (source: nil, target: 5),
        ]
        let order = WorkspacePlanBuilder.placementOrder(jobs: jobs, startingAt: 3)
        try expectEqual(order, [1, 0, 2, 3],
                        "frame-only on Space 3, then the carry 3→1, then Space 1's "
                        + "job, then the Space-less window")
        try expectEqual(WorkspacePlanBuilder.placementOrder(jobs: [], startingAt: 1), [])
        let all = WorkspacePlanBuilder.placementOrder(jobs: jobs, startingAt: 9)
        try expectEqual(all.sorted(), [0, 1, 2, 3], "every job is visited exactly once")
    }

    await Checks.shared.test("the drag grab point anchors to the zoom button") {
        let frame = CGRect(x: 100, y: 200, width: 1600, height: 900)
        let zoom = CGRect(x: 140, y: 208, width: 14, height: 14)
        try expectEqual(WorkspaceWindowMover.grabPoint(for: frame, zoomButton: zoom),
                        CGPoint(x: 172, y: 215),
                        "right of the green button, vertically centered on it")
        try expectEqual(WorkspaceWindowMover.grabPoint(for: frame, zoomButton: nil),
                        CGPoint(x: 240, y: 212),
                        "no zoom button falls back to the clamped title inset")
        let foreignZoom = CGRect(x: 5000, y: 5000, width: 14, height: 14)
        try expectEqual(WorkspaceWindowMover.grabPoint(for: frame,
                                                       zoomButton: foreignZoom),
                        CGPoint(x: 240, y: 212),
                        "a zoom frame outside the window is ignored")
        try expectEqual(WorkspaceWindowMover.grabPoint(
            for: CGRect(x: 0, y: 30, width: 120, height: 300), zoomButton: nil),
                        CGPoint(x: 40, y: 42),
                        "narrow windows keep at least 40pt from the left edge")
    }

    await Checks.shared.test("rules re-anchor to their Space UUID, ordinal as fallback") {
        var anchored = makeRule(bundleID: "com.spotify.client", slot: "Spotify", space: 2)
        anchored.spaceUUID = "U-B"
        var gone = makeRule(bundleID: "com.apple.finder", slot: "Finder", space: 3)
        gone.spaceUUID = "U-GONE"
        let legacy = makeRule(bundleID: "com.openai.codex", slot: "ChatGPT", space: 1)
        let resolved = WorkspacePlanBuilder.resolveSpaceOrdinals(
            [anchored, gone, legacy], currentUUIDs: ["U-C", "U-A", "U-B"])
        try expectEqual(resolved[0].spaceOrdinal, 3,
                        "U-B moved to position 3, so the rule follows it")
        try expectEqual(resolved[1].spaceOrdinal, 3,
                        "a vanished UUID keeps the captured ordinal")
        try expectEqual(resolved[2].spaceOrdinal, 1,
                        "pre-UUID rules keep their ordinal")
    }

    await Checks.shared.test("Dock assignment only covers whole-app single-Space moves") {
        let plan = WorkspacePlanBuilder.dockAssignPlan(
            jobs: [
                (bundleID: "com.spotify.client", windowID: 10, targetOrdinal: 1,
                 isMinimized: false),
                (bundleID: "com.brave.Browser", windowID: 30, targetOrdinal: 4,
                 isMinimized: false),
                (bundleID: "com.brave.Browser", windowID: 31, targetOrdinal: 5,
                 isMinimized: false),
                (bundleID: "com.apple.finder", windowID: 40, targetOrdinal: 6,
                 isMinimized: false),
                (bundleID: "com.openai.codex", windowID: 50, targetOrdinal: 2,
                 isMinimized: true),
            ],
            liveWindows: [
                makeWindow(id: 10, bundleID: "com.spotify.client",
                           frame: .zero, space: 501, ordinal: 1),
                makeWindow(id: 30, bundleID: "com.brave.Browser",
                           frame: .zero, space: 501, ordinal: 1),
                makeWindow(id: 31, bundleID: "com.brave.Browser",
                           frame: .zero, space: 501, ordinal: 1),
                makeWindow(id: 40, bundleID: "com.apple.finder",
                           frame: .zero, space: 501, ordinal: 1),
                makeWindow(id: 41, bundleID: "com.apple.finder",
                           frame: .zero, space: 502, ordinal: 2),
                makeWindow(id: 50, bundleID: "com.openai.codex",
                           frame: .zero, space: nil, ordinal: nil, minimized: true),
            ])
        try expectEqual(plan, ["com.spotify.client": 1],
                        "split targets (Brave), an extra elsewhere (Finder) and a "
                        + "minimized job (ChatGPT) all fall back to dragging")

        let extraOnTarget = WorkspacePlanBuilder.dockAssignPlan(
            jobs: [(bundleID: "com.apple.finder", windowID: 40, targetOrdinal: 2,
                    isMinimized: false)],
            liveWindows: [
                makeWindow(id: 40, bundleID: "com.apple.finder",
                           frame: .zero, space: 501, ordinal: 1),
                makeWindow(id: 41, bundleID: "com.apple.finder",
                           frame: .zero, space: 502, ordinal: 2),
            ])
        try expectEqual(extraOnTarget, ["com.apple.finder": 2],
                        "an extra already sitting on the target does not block")
    }

    await Checks.shared.test("schema 1 profiles load under schema 2 with nil UUIDs") {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("workspace_profiles.json")
        let v1 = """
        {"schemaVersion": 1, "profiles": [{
          "id": "\(UUID().uuidString)", "name": "Legacy",
          "display": {"displays": [], "screensHaveSeparateSpaces": false},
          "rules": [{"id": "\(UUID().uuidString)", "bundleID": "com.spotify.client",
                     "slotName": "Spotify", "displayUUID": "D-1", "spaceOrdinal": 2,
                     "frame": {"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5},
                     "stackingRank": 0, "isExcluded": false}],
          "createdAt": "2026-07-18T10:00:00Z", "updatedAt": "2026-07-18T10:00:00Z"}]}
        """
        try Data(v1.utf8).write(to: url)
        let store = WorkspaceProfileStore(directory: directory)
        try expectNil(store.loadFailure, String(describing: store.loadFailure))
        try expectEqual(store.profiles.count, 1)
        try expectEqual(store.profiles[0].rules[0].spaceOrdinal, 2)
        try expectNil(store.profiles[0].rules[0].spaceUUID,
                      "v1 rules migrate with no Space UUID")
    }

    await Checks.shared.test("the recipe registry covers the initial app inventory") {
        let registry = WorkspaceWindowRecipeRegistry.standard()
        let expected: Set<String> = [
            "com.spotify.client", "dev.kdrag0n.MacVirt",
            "com.google.antigravity-ide", "com.openai.codex",
            "com.anthropic.claudefordesktop", "com.brave.Browser",
            "com.apple.finder",
        ]
        try expectEqual(registry.creationRecipeBundleIDs, expected)
        try expectEqual(registry.recipeID(bundleID: "com.brave.Browser"),
                        "brave-new-window")
        try expectEqual(registry.recipeID(bundleID: "com.apple.finder"),
                        "finder-new-window")
        try expectNil(registry.recipe(bundleID: "com.apple.TextEdit"),
                      "apps outside the inventory have no creation recipe")
    }
}
