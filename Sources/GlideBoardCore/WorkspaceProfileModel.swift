import CoreGraphics
import Foundation

/// Canonical geometry space for workspace profiles is the Core Graphics
/// top-left global coordinate system (what AX and CGWindowList report).
/// AppKit bottom-left frames are converted once, at the resolver boundary.
enum WorkspaceSchema {
    static let version = 1
}

struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum WorkspaceGeometry {
    static func cgRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    static func normalize(_ frame: CGRect, in container: CGRect) -> NormalizedRect {
        guard container.width > 0, container.height > 0 else {
            return NormalizedRect(x: 0, y: 0, width: 0, height: 0)
        }
        return NormalizedRect(
            x: Double((frame.origin.x - container.origin.x) / container.width),
            y: Double((frame.origin.y - container.origin.y) / container.height),
            width: Double(frame.width / container.width),
            height: Double(frame.height / container.height))
    }

    static func denormalize(_ rect: NormalizedRect, in container: CGRect) -> CGRect {
        CGRect(x: (container.origin.x + CGFloat(rect.x) * container.width).rounded(),
               y: (container.origin.y + CGFloat(rect.y) * container.height).rounded(),
               width: (CGFloat(rect.width) * container.width).rounded(),
               height: (CGFloat(rect.height) * container.height).rounded())
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}

/// Persistent identity prefers stable hardware numbers; the UUID is kept as a
/// session-resolution hint because CGDirectDisplayIDs are transient.
struct DisplaySignature: Codable, Equatable {
    var uuid: String
    var localizedName: String
    var vendorNumber: UInt32
    var modelNumber: UInt32
    var serialNumber: UInt32
    var frame: CGRect
    var visibleFrame: CGRect
    var rotationDegrees: Int
    var isPrimary: Bool
    var userSpaceCount: Int
}

struct DisplayConfigurationSignature: Codable, Equatable {
    var displays: [DisplaySignature]
    var screensHaveSeparateSpaces: Bool
}

/// Titles are diagnostic hints only: window identity for multi-window apps is
/// the slot (bundle ID + capture order), never the mutable title.
struct WorkspaceWindowRule: Codable, Equatable, Identifiable {
    var id: UUID
    var bundleID: String
    var slotName: String
    var displayUUID: String
    var spaceOrdinal: Int
    var frame: NormalizedRect
    var stackingRank: Int
    var axRoleHint: String?
    var axSubroleHint: String?
    var titleHint: String?
    var recipeID: String?
    var isExcluded: Bool

    var isFrontWindow: Bool { stackingRank == 0 }
}

struct WorkspaceProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var display: DisplayConfigurationSignature
    var rules: [WorkspaceWindowRule]
    var createdAt: Date
    var updatedAt: Date
}

extension WorkspaceProfile {
    /// Makes the rule the front window of its Space, renumbering the other
    /// rules of that Space while preserving their relative order.
    mutating func promoteRuleToFront(_ ruleID: UUID) {
        guard let target = rules.first(where: { $0.id == ruleID }) else { return }
        let sameSpace = rules.indices
            .filter {
                rules[$0].spaceOrdinal == target.spaceOrdinal
                    && rules[$0].displayUUID == target.displayUUID
            }
            .sorted { rules[$0].stackingRank < rules[$1].stackingRank }
        var nextRank = 1
        for index in sameSpace {
            if rules[index].id == ruleID {
                rules[index].stackingRank = 0
            } else {
                rules[index].stackingRank = nextRank
                nextRank += 1
            }
        }
    }
}

struct WorkspaceLiveWindow: Equatable {
    var cgWindowID: UInt32
    var bundleID: String
    var frame: CGRect
    var spaceID: UInt64?
    var spaceOrdinal: Int?
    var isMinimized: Bool
    var title: String?
    var role: String?
    var subrole: String?
}

struct WorkspaceUndoWindowState: Equatable {
    var cgWindowID: UInt32
    var bundleID: String
    var slotName: String
    var spaceID: UInt64?
    var frame: CGRect
    var wasMinimized: Bool
    var stackingRank: Int
}

/// Session-scoped by design: the snapshot lives in memory only and dies with
/// the process, so undo can never resurrect a stale layout after relaunch.
struct WorkspaceUndoSnapshot: Equatable {
    var profileName: String
    var takenAt: Date
    var windows: [WorkspaceUndoWindowState]
}

enum WorkspaceRuleOutcome: Equatable {
    case satisfied
    case applied
    case launched
    case created
    case blocked(String)
    case failed(String)

    var isFailure: Bool {
        switch self {
        case .blocked, .failed: return true
        case .satisfied, .applied, .launched, .created: return false
        }
    }

    var label: String {
        switch self {
        case .satisfied: return "Already in place"
        case .applied: return "Placed"
        case .launched: return "Launched and placed"
        case .created: return "Window created and placed"
        case .blocked(let reason): return "Blocked: \(reason)"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

struct WorkspaceRuleResult: Equatable {
    var rule: WorkspaceWindowRule
    var outcome: WorkspaceRuleOutcome
}

struct WorkspaceApplyReport: Equatable {
    var profileID: UUID
    var profileName: String
    var results: [WorkspaceRuleResult]
    var extraWindows: [WorkspaceLiveWindow]
    var diagnostics: [String]
    var finishedAt: Date

    var failedRules: [WorkspaceWindowRule] {
        results.filter { $0.outcome.isFailure }.map(\.rule)
    }

    var headline: String {
        var parts: [String] = []
        func add(_ count: Int, _ singular: String, _ plural: String? = nil) {
            guard count > 0 else { return }
            parts.append("\(count) \(count == 1 ? singular : (plural ?? singular))")
        }
        add(results.count(of: .applied), "window placed", "windows placed")
        add(results.count(of: .satisfied), "already in place")
        add(results.count(of: .launched), "app launched", "apps launched")
        add(results.count(of: .created), "window created", "windows created")
        add(results.filter { if case .blocked = $0.outcome { return true } else { return false } }.count,
            "blocked")
        add(results.filter { if case .failed = $0.outcome { return true } else { return false } }.count,
            "failed")
        add(extraWindows.count, "extra window untouched", "extra windows untouched")
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

private extension Array where Element == WorkspaceRuleResult {
    func count(of outcome: WorkspaceRuleOutcome) -> Int {
        filter { $0.outcome == outcome }.count
    }
}
