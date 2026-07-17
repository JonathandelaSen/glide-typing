import AppKit

/// Guided read-only capture: visits every user Space on the display, records
/// the supported windows front-to-back, and returns to the original Space and
/// frontmost app even when a Space fails to capture. Nothing is saved here —
/// the controller previews the result and persists only after confirmation.
@MainActor
final class WorkspaceCaptureService {
    struct CapturedWindow: Equatable {
        var cgWindowID: UInt32
        var bundleID: String
        var appName: String
        var spaceOrdinal: Int
        var stackingRank: Int
        var frame: CGRect
        var title: String?
        var subrole: String?
    }

    struct CaptureResult {
        var profile: WorkspaceProfile
        var summaryLines: [String]
        var diagnostics: [String]
    }

    enum CaptureError: Error, CustomStringConvertible {
        case unavailable(String)
        case noDisplay
        case noSpaces
        case nothingCaptured

        var description: String {
            switch self {
            case .unavailable(let reason): return reason
            case .noDisplay: return "No display detected"
            case .noSpaces: return "No Spaces found; Numa never creates Spaces"
            case .nothingCaptured: return "No supported windows were found on any Space"
            }
        }
    }

    private let spaceManager: SpaceManaging
    private let catalog: WorkspaceWindowCatalog
    private let recipes: WorkspaceWindowRecipeRegistry

    init(spaceManager: SpaceManaging, catalog: WorkspaceWindowCatalog,
         recipes: WorkspaceWindowRecipeRegistry) {
        self.spaceManager = spaceManager
        self.catalog = catalog
        self.recipes = recipes
    }

    func captureMainDisplay(named name: String) async throws -> CaptureResult {
        guard case .available = spaceManager.capability else {
            if case .unavailable(let reason) = spaceManager.capability {
                throw CaptureError.unavailable(reason)
            }
            throw CaptureError.unavailable("Space access unavailable")
        }
        let signature = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        guard let display = signature.displays.first(where: \.isPrimary)
            ?? signature.displays.first else { throw CaptureError.noDisplay }
        let spaceIDs = spaceManager.orderedUserSpaceIDs(displayUUID: display.uuid)
        guard !spaceIDs.isEmpty else { throw CaptureError.noSpaces }

        let originalSpace = spaceManager.currentSpaceID(displayUUID: display.uuid)
        let originalApp = NSWorkspace.shared.frontmostApplication

        var entriesByWindowID: [UInt32: WorkspaceWindowCatalog.Entry] = [:]
        for entry in catalog.snapshot(spaceManager: spaceManager,
                                      displayUUID: display.uuid) {
            entriesByWindowID[entry.live.cgWindowID] = entry
        }

        var captured: [CapturedWindow] = []
        var diagnostics = DisplayConfigurationResolver.currentPrerequisiteIssues()
        for (index, spaceID) in spaceIDs.enumerated() {
            let ordinal = index + 1
            if spaceManager.currentSpaceID(displayUUID: display.uuid) != spaceID {
                spaceManager.switchToSpace(spaceID, displayUUID: display.uuid)
                let arrived = await settle(on: spaceID, displayUUID: display.uuid)
                if !arrived {
                    diagnostics.append("Space \(ordinal) could not be visited; skipped")
                    continue
                }
            }
            var rank = 0
            for windowID in catalog.onScreenWindowIDsFrontToBack() {
                guard let entry = entriesByWindowID[windowID] else { continue }
                captured.append(CapturedWindow(
                    cgWindowID: windowID,
                    bundleID: entry.live.bundleID,
                    appName: entry.appName,
                    spaceOrdinal: ordinal,
                    stackingRank: rank,
                    frame: entry.window.frame() ?? entry.live.frame,
                    title: entry.live.title,
                    subrole: entry.live.subrole))
                rank += 1
            }
        }

        if let originalSpace,
           spaceManager.currentSpaceID(displayUUID: display.uuid) != originalSpace {
            spaceManager.switchToSpace(originalSpace, displayUUID: display.uuid)
            _ = await settle(on: originalSpace, displayUUID: display.uuid)
        }
        originalApp?.activate()

        guard !captured.isEmpty else { throw CaptureError.nothingCaptured }

        let rules = Self.rules(from: captured, display: display,
                               recipeIDByBundle: recipeIDs())
        let now = Date()
        let profile = WorkspaceProfile(id: UUID(), name: name, display: signature,
                                       rules: rules, createdAt: now, updatedAt: now)
        return CaptureResult(profile: profile,
                             summaryLines: Self.summaryLines(profile: profile,
                                                             spaceCount: spaceIDs.count),
                             diagnostics: diagnostics)
    }

    private func recipeIDs() -> [String: String] {
        var byBundle: [String: String] = [:]
        for bundleID in recipes.creationRecipeBundleIDs {
            byBundle[bundleID] = recipes.recipeID(bundleID: bundleID)
        }
        return byBundle
    }

    private func settle(on spaceID: UInt64, displayUUID: String) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if spaceManager.currentSpaceID(displayUUID: displayUUID) == spaceID {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Pure rule construction so slot naming and normalization stay checkable.
    /// Multi-window apps get lettered slots in capture order (Brave A, B, …);
    /// titles are stored only as hints.
    static func rules(from captured: [CapturedWindow], display: DisplaySignature,
                      recipeIDByBundle: [String: String]) -> [WorkspaceWindowRule] {
        var totalPerBundle: [String: Int] = [:]
        for window in captured {
            totalPerBundle[window.bundleID, default: 0] += 1
        }
        var seenPerBundle: [String: Int] = [:]
        return captured
            .sorted { ($0.spaceOrdinal, $0.stackingRank, $0.cgWindowID)
                < ($1.spaceOrdinal, $1.stackingRank, $1.cgWindowID) }
            .map { window in
                let index = seenPerBundle[window.bundleID, default: 0]
                seenPerBundle[window.bundleID] = index + 1
                var slot = window.appName
                if totalPerBundle[window.bundleID, default: 0] > 1 {
                    let letter = Character(UnicodeScalar(65 + (index % 26))!)
                    slot = "\(window.appName) \(letter)"
                }
                return WorkspaceWindowRule(
                    id: UUID(),
                    bundleID: window.bundleID,
                    slotName: slot,
                    displayUUID: display.uuid,
                    spaceOrdinal: window.spaceOrdinal,
                    frame: WorkspaceGeometry.normalize(window.frame,
                                                       in: display.visibleFrame),
                    stackingRank: window.stackingRank,
                    axRoleHint: "AXWindow",
                    axSubroleHint: window.subrole,
                    titleHint: window.title,
                    recipeID: recipeIDByBundle[window.bundleID],
                    isExcluded: false)
            }
    }

    static func summaryLines(profile: WorkspaceProfile, spaceCount: Int) -> [String] {
        var lines: [String] = []
        if let display = profile.display.displays.first {
            lines.append("\(display.localizedName) — "
                + "\(Int(display.frame.width))×\(Int(display.frame.height)), "
                + "\(spaceCount) Spaces")
        }
        let bySpace = Dictionary(grouping: profile.rules, by: \.spaceOrdinal)
        for ordinal in bySpace.keys.sorted() {
            let slots = bySpace[ordinal]!
                .sorted { $0.stackingRank < $1.stackingRank }
                .map(\.slotName)
            lines.append("Space \(ordinal): \(slots.joined(separator: ", "))")
        }
        return lines
    }
}
