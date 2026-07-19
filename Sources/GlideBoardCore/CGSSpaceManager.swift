import CoreGraphics
import Foundation

/// Runtime-loaded private SkyLight adapter. Every symbol is resolved with
/// dlsym at init; any missing symbol turns the whole capability off with a
/// diagnostic instead of crashing (checkpoint 0 evidence:
/// docs/plans/evidence/05-checkpoint0-space-spike.txt). CGSGetWindowWorkspace
/// resolves on this machine but always reports workspace 0, so the window →
/// Space query uses CGSCopySpacesForWindows instead.
final class CGSSpaceManager: SpaceManaging {
    private typealias ConnectionID = Int32
    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias CopyManagedDisplaySpacesFn =
        @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias GetCurrentSpaceFn =
        @convention(c) (ConnectionID, CFString) -> UInt64
    private typealias MoveWindowsFn =
        @convention(c) (ConnectionID, CFArray, UInt64) -> Void
    private typealias CopySpacesForWindowsFn =
        @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?

    let capability: SpaceCapability
    private let connection: ConnectionID
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let getCurrentSpace: GetCurrentSpaceFn?
    private let moveWindowsFn: MoveWindowsFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?

    init() {
        var handles: [UnsafeMutableRawPointer] = []
        for path in [
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
        ] {
            if let handle = dlopen(path, RTLD_NOW) { handles.append(handle) }
        }
        func resolve(_ name: String) -> UnsafeMutableRawPointer? {
            for handle in handles {
                if let symbol = dlsym(handle, name) { return symbol }
            }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }

        let required = [
            "CGSMainConnectionID",
            "CGSCopyManagedDisplaySpaces",
            "CGSManagedDisplayGetCurrentSpace",
            "CGSMoveWindowsToManagedSpace",
            "CGSCopySpacesForWindows",
        ]
        var symbols: [String: UnsafeMutableRawPointer] = [:]
        var missing: [String] = []
        for name in required {
            if let pointer = resolve(name) {
                symbols[name] = pointer
            } else {
                missing.append(name)
            }
        }

        if missing.isEmpty, let main = symbols["CGSMainConnectionID"] {
            capability = .available
            connection = unsafeBitCast(main, to: MainConnectionFn.self)()
            copyManagedDisplaySpaces = unsafeBitCast(
                symbols["CGSCopyManagedDisplaySpaces"]!, to: CopyManagedDisplaySpacesFn.self)
            getCurrentSpace = unsafeBitCast(
                symbols["CGSManagedDisplayGetCurrentSpace"]!, to: GetCurrentSpaceFn.self)
            moveWindowsFn = unsafeBitCast(
                symbols["CGSMoveWindowsToManagedSpace"]!, to: MoveWindowsFn.self)
            copySpacesForWindows = unsafeBitCast(
                symbols["CGSCopySpacesForWindows"]!, to: CopySpacesForWindowsFn.self)
        } else {
            capability = .unavailable(reason:
                "Workspace profiles are disabled: this macOS build does not expose "
                + missing.joined(separator: ", "))
            connection = 0
            copyManagedDisplaySpaces = nil
            getCurrentSpace = nil
            moveWindowsFn = nil
            copySpacesForWindows = nil
        }
        switch capability {
        case .available:
            WorkspaceLog.write("CGS adapter ready, connection \(connection)")
        case .unavailable(let reason):
            WorkspaceLog.write("CGS adapter disabled: \(reason)")
        }
    }

    private func displayEntry(forUUID uuid: String) -> [String: Any]? {
        guard let copyManagedDisplaySpaces,
              let entries = copyManagedDisplaySpaces(connection)?.takeRetainedValue()
                as? [[String: Any]] else { return nil }
        if let exact = entries.first(where: { $0["Display Identifier"] as? String == uuid }) {
            return exact
        }
        // Single-display sessions may report the identifier as "Main".
        return entries.count == 1 ? entries[0] : nil
    }

    func orderedUserSpaceIDs(displayUUID: String) -> [UInt64] {
        guard let entry = displayEntry(forUUID: displayUUID),
              let spaces = entry["Spaces"] as? [[String: Any]] else { return [] }
        return spaces.compactMap { space in
            guard (space["type"] as? Int ?? -1) == 0 else { return nil }
            return (space["id64"] as? NSNumber)?.uint64Value
        }
    }

    func currentSpaceID(displayUUID: String) -> UInt64? {
        guard let getCurrentSpace else { return nil }
        let id = getCurrentSpace(connection, displayUUID as CFString)
        return id == 0 ? nil : id
    }

    func spaceID(ofWindow windowID: UInt32) -> UInt64? {
        guard let copySpacesForWindows else { return nil }
        let windows = [NSNumber(value: windowID)] as CFArray
        let spaces = copySpacesForWindows(connection, 7, windows)?
            .takeRetainedValue() as? [NSNumber]
        return spaces?.first?.uint64Value
    }

    func moveWindows(_ windowIDs: [UInt32], toSpace spaceID: UInt64) {
        guard let moveWindowsFn, !windowIDs.isEmpty else { return }
        WorkspaceLog.write("CGS move windows \(windowIDs) -> space \(spaceID)")
        let windows = windowIDs.map { NSNumber(value: $0) } as CFArray
        moveWindowsFn(connection, windows, spaceID)
    }

}
