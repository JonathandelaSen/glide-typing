import AppKit
import ApplicationServices

/// Read/write access to one AX window. All frames are CG top-left global.
struct WorkspaceAXWindow {
    let element: AXUIElement

    private func copyValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                            &value) == .success else { return nil }
        return value
    }

    func frame() -> CGRect? {
        guard let positionValue = copyValue(kAXPositionAttribute),
              let sizeValue = copyValue(kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Position → size → position: some apps clamp the first move until the
    /// size fits the target display region.
    func setFrame(_ rect: CGRect) {
        setPosition(rect.origin)
        var size = rect.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        setPosition(rect.origin)
    }

    private func setPosition(_ origin: CGPoint) {
        var origin = origin
        if let positionValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString,
                                         positionValue)
        }
    }

    func isMinimized() -> Bool {
        copyValue(kAXMinimizedAttribute) as? Bool ?? false
    }

    func setMinimized(_ minimized: Bool) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func title() -> String? { copyValue(kAXTitleAttribute) as? String }
    func role() -> String? { copyValue(kAXRoleAttribute) as? String }
    func subrole() -> String? { copyValue(kAXSubroleAttribute) as? String }
}

/// Maps running apps, their AX windows, and CG window IDs into one snapshot.
/// The CG window ID comes from the private `_AXUIElementGetWindow` (resolved
/// dynamically); without it a window can still be matched through its CG
/// frame, and if both fail the window is skipped rather than guessed.
@MainActor
final class WorkspaceWindowCatalog {
    struct Entry {
        var live: WorkspaceLiveWindow
        var window: WorkspaceAXWindow
        var pid: pid_t
        var appName: String
    }

    private typealias AXGetWindowFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private let axGetWindow: AXGetWindowFn?

    init() {
        let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
            RTLD_NOW)
        let symbol = handle.flatMap { dlsym($0, "_AXUIElementGetWindow") }
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        axGetWindow = symbol.map { unsafeBitCast($0, to: AXGetWindowFn.self) }
    }

    func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.activationPolicy == .regular ? app.bundleIdentifier : nil
        })
    }

    func snapshot(spaceManager: SpaceManaging, displayUUID: String) -> [Entry] {
        var ordinalBySpaceID: [UInt64: Int] = [:]
        for (index, spaceID) in spaceManager.orderedUserSpaceIDs(displayUUID: displayUUID)
            .enumerated() {
            ordinalBySpaceID[spaceID] = index + 1
        }

        let cgBoundsByPID = cgWindowBounds()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var entries: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString,
                                                &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            for element in axWindows {
                let window = WorkspaceAXWindow(element: element)
                guard window.role() == kAXWindowRole else { continue }
                let subrole = window.subrole()
                guard subrole == nil || subrole == kAXStandardWindowSubrole else { continue }
                guard let frame = window.frame(),
                      frame.width >= 50, frame.height >= 50 else { continue }
                guard let windowID = windowID(of: element, frame: frame,
                                              pid: app.processIdentifier,
                                              cgBoundsByPID: cgBoundsByPID) else { continue }
                let spaceID = spaceManager.spaceID(ofWindow: windowID)
                entries.append(Entry(
                    live: WorkspaceLiveWindow(
                        cgWindowID: windowID,
                        bundleID: bundleID,
                        frame: frame,
                        spaceID: spaceID,
                        spaceOrdinal: spaceID.flatMap { ordinalBySpaceID[$0] },
                        isMinimized: window.isMinimized(),
                        title: window.title(),
                        role: kAXWindowRole,
                        subrole: subrole),
                    window: window,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? bundleID))
            }
        }
        return entries
    }

    private func windowID(of element: AXUIElement, frame: CGRect, pid: pid_t,
                          cgBoundsByPID: [pid_t: [(id: UInt32, bounds: CGRect)]])
        -> UInt32? {
        if let axGetWindow {
            var windowID: UInt32 = 0
            if axGetWindow(element, &windowID) == .success, windowID != 0 {
                return windowID
            }
        }
        let candidates = (cgBoundsByPID[pid] ?? []).filter {
            WorkspaceGeometry.approximatelyEqual($0.bounds, frame, tolerance: 2)
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private func cgWindowBounds() -> [pid_t: [(id: UInt32, bounds: CGRect)]] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var byPID: [pid_t: [(id: UInt32, bounds: CGRect)]] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation:
                    boundsDict as CFDictionary) else { continue }
            byPID[pid, default: []].append((number, bounds))
        }
        return byPID
    }

    /// Front-to-back CG window IDs currently on screen — the stacking order
    /// of the active Space. Only meaningful for the Space being displayed.
    func onScreenWindowIDsFrontToBack() -> [UInt32] {
        windowIDsFrontToBack(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// Global window-server order across all Spaces; per-Space slices only
    /// approximate stacking, good enough for the undo snapshot's ranks.
    func allWindowIDsFrontToBack() -> [UInt32] {
        windowIDsFrontToBack(options: [.optionAll, .excludeDesktopElements])
    }

    private func windowIDsFrontToBack(options: CGWindowListOption) -> [UInt32] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? UInt32
            else { return nil }
            return number
        }
    }
}
