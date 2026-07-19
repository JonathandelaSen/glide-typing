import AppKit

/// Traversal-free capture: every window is asked for its own Space through
/// the adapter, which answers precisely for windows on any Space, and
/// per-Space stacking comes from the global front-to-back window order. The
/// v36 guided traversal was removed after live evidence showed the on-screen
/// window list keeps reporting the previous Space's windows for over a
/// second after a switch, which replicated one Space's windows across all of
/// them (docs/plans/05, capture incident 2026-07-18). Nothing is saved here
/// — the controller previews the result and persists only after
/// confirmation.
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
        WorkspaceLog.write("capture start: \(spaceIDs.count) spaces on "
            + "\(display.localizedName), no traversal")

        let entries = catalog.snapshot(spaceManager: spaceManager,
                                       displayUUID: display.uuid)
        let captured = Self.capturedWindows(
            from: entries.map { entry in
                CaptureCandidate(cgWindowID: entry.live.cgWindowID,
                                 bundleID: entry.live.bundleID,
                                 appName: entry.appName,
                                 spaceOrdinal: entry.live.spaceOrdinal,
                                 isMinimized: entry.live.isMinimized,
                                 frame: entry.live.frame,
                                 title: entry.live.title,
                                 subrole: entry.live.subrole)
            },
            globalOrderFrontToBack: catalog.allWindowIDsFrontToBack())

        var diagnostics = DisplayConfigurationResolver.currentPrerequisiteIssues()
        let skipped = entries.count - captured.count
        if skipped > 0 {
            diagnostics.append("\(skipped) window(s) skipped: minimized or not "
                + "assigned to any Space")
        }
        WorkspaceLog.write("capture done: \(captured.count) windows"
            + (diagnostics.isEmpty ? "" : "; \(diagnostics.joined(separator: "; "))"))

        guard !captured.isEmpty else { throw CaptureError.nothingCaptured }

        let rules = Self.rules(from: captured, display: display,
                               spaceUUIDs: spaceManager.orderedUserSpaceUUIDs(
                                displayUUID: display.uuid),
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

    struct CaptureCandidate: Equatable {
        var cgWindowID: UInt32
        var bundleID: String
        var appName: String
        var spaceOrdinal: Int?
        var isMinimized: Bool
        var frame: CGRect
        var title: String?
        var subrole: String?
    }

    /// Pure shaping of a snapshot into captured windows: a window must sit on
    /// exactly one known user Space and not be minimized; each window ID is
    /// captured once; per-Space stacking rank follows the global
    /// front-to-back order (rank 0 = that Space's front window).
    static func capturedWindows(from candidates: [CaptureCandidate],
                                globalOrderFrontToBack: [UInt32]) -> [CapturedWindow] {
        var globalRank: [UInt32: Int] = [:]
        for (index, windowID) in globalOrderFrontToBack.enumerated() {
            globalRank[windowID] = index
        }
        var seen = Set<UInt32>()
        var eligible: [CaptureCandidate] = []
        for candidate in candidates {
            guard candidate.spaceOrdinal != nil, !candidate.isMinimized,
                  !seen.contains(candidate.cgWindowID) else { continue }
            seen.insert(candidate.cgWindowID)
            eligible.append(candidate)
        }
        var rankCounters: [Int: Int] = [:]
        return eligible
            .sorted {
                let left = ($0.spaceOrdinal!, globalRank[$0.cgWindowID] ?? Int.max,
                            $0.cgWindowID)
                let right = ($1.spaceOrdinal!, globalRank[$1.cgWindowID] ?? Int.max,
                             $1.cgWindowID)
                return left < right
            }
            .map { candidate in
                let ordinal = candidate.spaceOrdinal!
                let rank = rankCounters[ordinal, default: 0]
                rankCounters[ordinal] = rank + 1
                return CapturedWindow(cgWindowID: candidate.cgWindowID,
                                      bundleID: candidate.bundleID,
                                      appName: candidate.appName,
                                      spaceOrdinal: ordinal,
                                      stackingRank: rank,
                                      frame: candidate.frame,
                                      title: candidate.title,
                                      subrole: candidate.subrole)
            }
    }

    /// Pure rule construction so slot naming and normalization stay checkable.
    /// Multi-window apps get lettered slots in capture order (Brave A, B, …);
    /// titles are stored only as hints, and each rule anchors to its Space's
    /// stable UUID with the ordinal kept as fallback.
    static func rules(from captured: [CapturedWindow], display: DisplaySignature,
                      spaceUUIDs: [String],
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
                let uuidIndex = window.spaceOrdinal - 1
                let spaceUUID = spaceUUIDs.indices.contains(uuidIndex)
                    && !spaceUUIDs[uuidIndex].isEmpty
                    ? spaceUUIDs[uuidIndex] : nil
                return WorkspaceWindowRule(
                    id: UUID(),
                    bundleID: window.bundleID,
                    slotName: slot,
                    displayUUID: display.uuid,
                    spaceOrdinal: window.spaceOrdinal,
                    spaceUUID: spaceUUID,
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
