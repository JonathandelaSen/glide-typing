import AppKit
@testable import GlideBoardCore

// Workspace lab: exercises the real capture → apply → undo pipeline from the
// command line. Commands:
//   capture                 capture and print the profile, save nothing
//   move <winID> <spaceID>  carry one window to a Space via the gesture mover
//   e2e [bundleID]          capture, apply (expect no-op), displace one window
//                           of bundleID (default ChatGPT), apply again, undo,
//                           apply once more; the layout ends as it started

@MainActor
func run() async {
    let spaceManager = CGSSpaceManager()
    let catalog = WorkspaceWindowCatalog()
    let recipes = WorkspaceWindowRecipeRegistry.standard()
    let launcher = WorkspaceApplicationLauncher()
    let undoStore = WorkspaceUndoStore()
    let mover = WorkspaceWindowMover(spaceManager: spaceManager, catalog: catalog)
    let captureService = WorkspaceCaptureService(spaceManager: spaceManager,
                                                 catalog: catalog, recipes: recipes)
    let executor = WorkspaceProfileExecutor(spaceManager: spaceManager,
                                            catalog: catalog, launcher: launcher,
                                            recipes: recipes, undoStore: undoStore,
                                            mover: mover)

    print("AX trusted: \(AXIsProcessTrusted())")
    guard case .available = spaceManager.capability else {
        print("CGS unavailable: \(spaceManager.capability)")
        exit(1)
    }

    func printProfile(_ profile: WorkspaceProfile) {
        for line in WorkspaceCaptureService.summaryLines(
            profile: profile,
            spaceCount: profile.display.displays.first?.userSpaceCount ?? 0) {
            print("   \(line)")
        }
    }

    func printReport(_ report: WorkspaceApplyReport, expect: String) {
        print("   report: \(report.headline)   [expected: \(expect)]")
        for result in report.results where result.outcome != .satisfied {
            print("      \(result.rule.slotName): \(result.outcome.label)")
        }
        for diagnostic in report.diagnostics {
            print("      diag: \(diagnostic)")
        }
    }

    let arguments = CommandLine.arguments
    let command = arguments.count > 1 ? arguments[1] : "capture"

    switch command {
    case "capture":
        do {
            let result = try await captureService.captureMainDisplay(named: "Lab Capture")
            print("== capture: \(result.profile.rules.count) rules")
            printProfile(result.profile)
            for diagnostic in result.diagnostics { print("   diag: \(diagnostic)") }
        } catch {
            print("capture failed: \(error)")
            exit(1)
        }

    case "move":
        guard arguments.count > 3, let windowID = UInt32(arguments[2]),
              let targetSpaceID = UInt64(arguments[3]) else {
            print("usage: move <windowID> <spaceID>")
            exit(2)
        }
        let signature = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        guard let display = signature.displays.first(where: \.isPrimary)
            ?? signature.displays.first else { exit(1) }
        let spaceIDs = spaceManager.orderedUserSpaceIDs(displayUUID: display.uuid)
        guard let targetIndex = spaceIDs.firstIndex(of: targetSpaceID) else {
            print("space \(targetSpaceID) not in \(spaceIDs)")
            exit(1)
        }
        let entries = catalog.snapshot(spaceManager: spaceManager,
                                       displayUUID: display.uuid)
        guard let entry = entries.first(where: { $0.live.cgWindowID == windowID }) else {
            print("window \(windowID) not in the catalog")
            exit(1)
        }
        guard let sourceOrdinal = entry.live.spaceOrdinal else {
            print("window \(windowID) is not on any Space")
            exit(1)
        }
        print("window \(windowID) [\(entry.live.bundleID)]: "
            + "Space \(sourceOrdinal) -> \(targetIndex + 1)")
        guard await mover.switchToOrdinal(sourceOrdinal, displayUUID: display.uuid,
                                          spaceIDs: spaceIDs) else {
            print("could not switch to the window's Space")
            exit(1)
        }
        if let failure = await mover.carryWindow(windowID, pid: entry.pid,
                                                 toOrdinal: targetIndex + 1,
                                                 displayUUID: display.uuid,
                                                 spaceIDs: spaceIDs) {
            print("carry failed: \(failure)")
            exit(1)
        }
        print("moved: window now on space "
            + "\(spaceManager.spaceID(ofWindow: windowID).map(String.init) ?? "?")")

    case "e2e":
        let targetBundle = arguments.count > 2 ? arguments[2] : "com.openai.codex"
        do {
            print("== 1. capture")
            let result = try await captureService.captureMainDisplay(named: "Lab E2E")
            let profile = result.profile
            print("   \(profile.rules.count) rules")
            printProfile(profile)

            print("== 2. apply immediately (idempotency)")
            let first = await executor.apply(profile)
            printReport(first, expect: "everything already in place")

            print("== 3. displace one \(targetBundle) window via the mover")
            guard let display = profile.display.displays.first else { exit(1) }
            let spaces = spaceManager.orderedUserSpaceIDs(displayUUID: display.uuid)
            let entries = catalog.snapshot(spaceManager: spaceManager,
                                           displayUUID: display.uuid)
            guard let victim = entries.first(where: {
                $0.live.bundleID == targetBundle && $0.live.spaceOrdinal != nil
            }), let victimOrdinal = victim.live.spaceOrdinal else {
                print("no \(targetBundle) window found; aborting without changes")
                exit(1)
            }
            let windowID = victim.live.cgWindowID
            let originalSpace = victim.live.spaceID
            let originalFrame = victim.live.frame
            let otherOrdinal = victimOrdinal == spaces.count
                ? victimOrdinal - 1 : victimOrdinal + 1
            guard await mover.switchToOrdinal(victimOrdinal, displayUUID: display.uuid,
                                              spaceIDs: spaces) else {
                print("could not reach the victim's Space"); exit(1)
            }
            if let failure = await mover.carryWindow(windowID, pid: victim.pid,
                                                     toOrdinal: otherOrdinal,
                                                     displayUUID: display.uuid,
                                                     spaceIDs: spaces) {
                print("displacement failed: \(failure)"); exit(1)
            }
            catalog.axWindow(for: windowID, pid: victim.pid)?
                .setFrame(CGRect(x: originalFrame.origin.x + 120,
                                 y: originalFrame.origin.y + 80,
                                 width: max(500, originalFrame.width - 400),
                                 height: max(400, originalFrame.height - 300)))
            try? await Task.sleep(nanoseconds: 600_000_000)
            print("   window \(windowID): space "
                + "\(originalSpace.map(String.init) ?? "?") -> "
                + "\(spaceManager.spaceID(ofWindow: windowID).map(String.init) ?? "?")"
                + ", frame shrunk")

            print("== 4. apply again (must move it back)")
            let second = await executor.apply(profile)
            printReport(second, expect: "1 window placed")
            let back = spaceManager.spaceID(ofWindow: windowID)
            let backFrame = catalog.cgBounds(of: windowID) ?? .zero
            let restored = back == originalSpace && WorkspaceGeometry
                .approximatelyEqual(backFrame, originalFrame, tolerance: 6)
            print("   verification: space \(back.map(String.init) ?? "?") "
                + "frame \(WorkspaceLog.describe(backFrame)) restored=\(restored)")

            print("== 5. undo (must re-displace it)")
            for line in await executor.undoLastApply() { print("   \(line)") }
            let afterUndo = spaceManager.spaceID(ofWindow: windowID)
            print("   after undo: space \(afterUndo.map(String.init) ?? "?") "
                + "(displaced ordinal was \(otherOrdinal))")

            print("== 6. final apply (leave everything as captured)")
            let third = await executor.apply(profile)
            printReport(third, expect: "1 window placed")
            let final = spaceManager.spaceID(ofWindow: windowID)
            let finalFrame = catalog.cgBounds(of: windowID) ?? .zero
            let ok = final == originalSpace && WorkspaceGeometry
                .approximatelyEqual(finalFrame, originalFrame, tolerance: 6)
            print("   final state: space \(final.map(String.init) ?? "?") "
                + "frame \(WorkspaceLog.describe(finalFrame)) restored=\(ok)")
            print(ok && restored ? "E2E: PASS" : "E2E: FAIL")
            exit(ok && restored ? 0 : 1)
        } catch {
            print("e2e failed: \(error)")
            exit(1)
        }

    default:
        print("unknown command \(command)")
        exit(2)
    }
    exit(0)
}

_ = NSApplication.shared
Task { @MainActor in
    await run()
}
RunLoop.main.run()
