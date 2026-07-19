import CoreGraphics
import Foundation

enum WorkspacePlannedAction: Equatable {
    case none
    case move
    case launchAndAdopt
    case createWindow
    case blocked(String)
}

struct WorkspaceRulePlan: Equatable {
    var rule: WorkspaceWindowRule
    var action: WorkspacePlannedAction
    var matchedWindowID: UInt32?
    var targetSpaceID: UInt64?
    var targetFrame: CGRect?
    var needsSpaceMove: Bool
    var needsFrameChange: Bool
    var needsUnminimize: Bool
}

struct WorkspaceApplyPlan: Equatable {
    var profileID: UUID
    var profileName: String
    var rulePlans: [WorkspaceRulePlan]
    var extraWindows: [WorkspaceLiveWindow]
    var diagnostics: [String]

    var needsLaunchOrCreate: Bool {
        rulePlans.contains {
            $0.action == .launchAndAdopt || $0.action == .createWindow
        }
    }
}

struct WorkspacePlanInput {
    var profile: WorkspaceProfile
    var liveWindows: [WorkspaceLiveWindow]
    var runningBundleIDs: Set<String>
    var spaceIDByOrdinal: [Int: UInt64]
    var visibleFrame: CGRect
    var creationRecipeBundleIDs: Set<String>
    var frameTolerance: CGFloat = 3
}

/// Pure planning: matches saved rules to live windows and decides, without
/// mutating anything, what applying the profile would do. Deterministic for
/// the same input, and a window is never assigned to two rules, which is what
/// makes reapplying idempotent instead of duplicative.
enum WorkspacePlanBuilder {
    static func build(_ input: WorkspacePlanInput) -> WorkspaceApplyPlan {
        let rules = input.profile.rules.filter { !$0.isExcluded }
        let profileBundles = Set(rules.map(\.bundleID))
        var assignedWindowIDs = Set<UInt32>()
        var matches: [UUID: WorkspaceLiveWindow] = [:]

        for bundleID in profileBundles.sorted() {
            let bundleRules = rules.filter { $0.bundleID == bundleID }
            let bundleWindows = input.liveWindows
                .filter { $0.bundleID == bundleID }
                .sorted { $0.cgWindowID < $1.cgWindowID }
            for rule in bundleRules {
                let target = WorkspaceGeometry.denormalize(rule.frame,
                                                           in: input.visibleFrame)
                let candidate = bundleWindows
                    .filter { !assignedWindowIDs.contains($0.cgWindowID) }
                    .min { cost($0, rule: rule, target: target)
                        < cost($1, rule: rule, target: target) }
                if let candidate {
                    assignedWindowIDs.insert(candidate.cgWindowID)
                    matches[rule.id] = candidate
                }
            }
        }

        let rulePlans = rules.map { rule -> WorkspaceRulePlan in
            let target = WorkspaceGeometry.denormalize(rule.frame, in: input.visibleFrame)
            guard let targetSpace = input.spaceIDByOrdinal[rule.spaceOrdinal] else {
                return WorkspaceRulePlan(
                    rule: rule,
                    action: .blocked("Space \(rule.spaceOrdinal) does not exist; "
                        + "Numa never creates Spaces"),
                    matchedWindowID: nil, targetSpaceID: nil, targetFrame: target,
                    needsSpaceMove: false, needsFrameChange: false,
                    needsUnminimize: false)
            }
            if let window = matches[rule.id] {
                let needsSpaceMove = window.spaceID != targetSpace
                let needsFrameChange = !WorkspaceGeometry.approximatelyEqual(
                    window.frame, target, tolerance: input.frameTolerance)
                let needsUnminimize = window.isMinimized
                let changes = needsSpaceMove || needsFrameChange || needsUnminimize
                return WorkspaceRulePlan(
                    rule: rule,
                    action: changes ? .move : .none,
                    matchedWindowID: window.cgWindowID,
                    targetSpaceID: targetSpace, targetFrame: target,
                    needsSpaceMove: needsSpaceMove,
                    needsFrameChange: needsFrameChange,
                    needsUnminimize: needsUnminimize)
            }
            let action: WorkspacePlannedAction
            if !input.runningBundleIDs.contains(rule.bundleID) {
                action = .launchAndAdopt
            } else if input.creationRecipeBundleIDs.contains(rule.bundleID) {
                action = .createWindow
            } else {
                action = .blocked("\(rule.slotName) is running without a matching window "
                    + "and has no tested window-creation recipe")
            }
            return WorkspaceRulePlan(
                rule: rule, action: action,
                matchedWindowID: nil, targetSpaceID: targetSpace, targetFrame: target,
                needsSpaceMove: true, needsFrameChange: true, needsUnminimize: false)
        }

        let extras = input.liveWindows.filter {
            profileBundles.contains($0.bundleID)
                && !assignedWindowIDs.contains($0.cgWindowID)
        }

        var diagnostics: [String] = []
        if rules.isEmpty {
            diagnostics.append("The profile has no active window rules")
        }

        return WorkspaceApplyPlan(
            profileID: input.profile.id,
            profileName: input.profile.name,
            rulePlans: rulePlans,
            extraWindows: extras,
            diagnostics: diagnostics)
    }

    /// Where each rule's captured desktop sits NOW, by UUID. Applying is
    /// positional (the captured ordinal), so this is only the telltale for
    /// "the desktops were reordered since capture" diagnostics. Rules whose
    /// UUID is missing keep their captured ordinal.
    static func resolveSpaceOrdinals(_ rules: [WorkspaceWindowRule],
                                     currentUUIDs: [String]) -> [WorkspaceWindowRule] {
        rules.map { rule in
            guard let uuid = rule.spaceUUID, !uuid.isEmpty,
                  let index = currentUUIDs.firstIndex(of: uuid) else { return rule }
            var rule = rule
            rule.spaceOrdinal = index + 1
            return rule
        }
    }

    /// Bundles whose cross-Space moves can ride the Dock's "Assign To This
    /// Desktop" command instead of a drag: every job of the bundle targets
    /// the same Space, and every other live window of the bundle already
    /// sits there — the assignment gathers ALL of an app's windows, and
    /// extras must never be moved.
    static func dockAssignPlan(jobs: [(bundleID: String, windowID: UInt32,
                                       targetOrdinal: Int, isMinimized: Bool)],
                               liveWindows: [WorkspaceLiveWindow]) -> [String: Int] {
        var plan: [String: Int] = [:]
        let jobWindowIDs = Set(jobs.map(\.windowID))
        for bundleID in Set(jobs.map(\.bundleID)) {
            let bundleJobs = jobs.filter { $0.bundleID == bundleID }
            let targets = Set(bundleJobs.map(\.targetOrdinal))
            guard targets.count == 1, let target = targets.first,
                  !bundleJobs.contains(where: \.isMinimized) else { continue }
            let untouched = liveWindows.filter {
                $0.bundleID == bundleID && !jobWindowIDs.contains($0.cgWindowID)
                    && !$0.isMinimized
            }
            guard untouched.allSatisfy({ $0.spaceOrdinal == target }) else { continue }
            plan[bundleID] = target
        }
        return plan
    }

    /// Visit order for placement jobs that minimizes Space switches: keep
    /// consuming jobs whose source is the Space the cursor is on (windows
    /// without a Space can be handled anywhere); the cursor then follows
    /// each job's target.
    static func placementOrder(jobs: [(source: Int?, target: Int)],
                               startingAt start: Int) -> [Int] {
        var order: [Int] = []
        var remaining = Array(jobs.indices)
        var cursor = start
        while !remaining.isEmpty {
            // Frame-only fixes on the current Space go before carries that
            // leave it, so no Space needs a second visit.
            let next = remaining.first {
                jobs[$0].source == cursor && jobs[$0].target == cursor
            }
                ?? remaining.first { jobs[$0].source == cursor }
                ?? remaining.first { jobs[$0].source == nil }
                ?? remaining[0]
            order.append(next)
            remaining.removeAll { $0 == next }
            cursor = jobs[next].target
        }
        return order
    }

    /// Slot assignment cost. Space distance dominates, then geometry, and the
    /// window ID breaks ties deterministically via the stable sort order of
    /// the candidates. Titles are never part of identity.
    private static func cost(_ window: WorkspaceLiveWindow,
                             rule: WorkspaceWindowRule,
                             target: CGRect) -> Double {
        var cost = 0.0
        if let ordinal = window.spaceOrdinal {
            cost += Double(abs(ordinal - rule.spaceOrdinal)) * 100_000
        } else {
            cost += 300_000
        }
        if window.isMinimized { cost += 50_000 }
        cost += Double(abs(window.frame.midX - target.midX)
            + abs(window.frame.midY - target.midY))
        cost += Double(abs(window.frame.width - target.width)
            + abs(window.frame.height - target.height))
        return cost
    }
}
