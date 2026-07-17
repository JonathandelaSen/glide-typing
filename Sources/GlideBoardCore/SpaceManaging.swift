import Foundation

enum SpaceCapability: Equatable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool { self == .available }
}

/// The narrow contract the private Space adapter implements. It owns no
/// launch, matching, geometry, persistence, or UI logic.
protocol SpaceManaging: AnyObject {
    var capability: SpaceCapability { get }
    func orderedUserSpaceIDs(displayUUID: String) -> [UInt64]
    func currentSpaceID(displayUUID: String) -> UInt64?
    func spaceID(ofWindow windowID: UInt32) -> UInt64?
    func moveWindows(_ windowIDs: [UInt32], toSpace spaceID: UInt64)
    func switchToSpace(_ spaceID: UInt64, displayUUID: String)
}
