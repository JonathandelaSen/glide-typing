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

    /// The zoom (green) button's frame anchors a safe drag point: the strip
    /// right of it is draggable chrome even in custom-title-bar apps.
    func zoomButtonFrame() -> CGRect? {
        guard let value = copyValue(kAXZoomButtonAttribute) else { return nil }
        let button = WorkspaceAXWindow(element: value as! AXUIElement)
        return button.frame()
    }
}

/// CG-primary window snapshot: CGWindowList sees every Space's windows with
/// their frames, and the adapter answers each window's Space precisely. The
/// Accessibility API only exposes windows of the ACTIVE Space (verified live
/// 2026-07-18), so AX merely enriches entries with elements, titles,
/// subroles, and minimized state when it can see them.
@MainActor
final class WorkspaceWindowCatalog {
    struct Entry {
        var live: WorkspaceLiveWindow
        var axWindow: WorkspaceAXWindow?
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
        let started = Date()
        var ordinalBySpaceID: [UInt64: Int] = [:]
        for (index, spaceID) in spaceManager.orderedUserSpaceIDs(displayUUID: displayUUID)
            .enumerated() {
            ordinalBySpaceID[spaceID] = index + 1
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        struct AXInfo {
            var window: WorkspaceAXWindow
            var minimized: Bool
            var title: String?
            var subrole: String?
        }
        var axByWindowID: [UInt32: AXInfo] = [:]
        var appByPID: [pid_t: NSRunningApplication] = [:]
        var appsScanned = 0
        var axFailures: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier else { continue }
            appByPID[app.processIdentifier] = app
            appsScanned += 1
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            let axError = AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &value)
            guard axError == .success, let axWindows = value as? [AXUIElement] else {
                axFailures.append("\(bundleID)=\(axError.rawValue)")
                continue
            }
            for element in axWindows {
                let window = WorkspaceAXWindow(element: element)
                guard let windowID = windowID(of: element) else { continue }
                axByWindowID[windowID] = AXInfo(window: window,
                                                minimized: window.isMinimized(),
                                                title: window.title(),
                                                subrole: window.subrole())
            }
        }

        var entries: [Entry] = []
        var skippedSpaceless = 0
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = appByPID[pid],
                  let bundleID = app.bundleIdentifier,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation:
                    boundsDict as CFDictionary),
                  bounds.width >= 50, bounds.height >= 50 else { continue }
            let ax = axByWindowID[windowID]
            if let subrole = ax?.subrole, subrole != kAXStandardWindowSubrole { continue }
            let spaceID = spaceManager.spaceID(ofWindow: windowID)
            // Spaceless CG windows are junk panels unless AX confirms they
            // are real minimized windows.
            if spaceID == nil && ax?.minimized != true {
                skippedSpaceless += 1
                continue
            }
            entries.append(Entry(
                live: WorkspaceLiveWindow(
                    cgWindowID: windowID,
                    bundleID: bundleID,
                    frame: (ax?.minimized == true ? ax?.window.frame() : nil) ?? bounds,
                    spaceID: spaceID,
                    spaceOrdinal: spaceID.flatMap { ordinalBySpaceID[$0] },
                    isMinimized: ax?.minimized ?? false,
                    title: ax?.title,
                    role: "AXWindow",
                    subrole: ax?.subrole),
                axWindow: ax?.window,
                pid: pid,
                appName: app.localizedName ?? bundleID))
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var summary = "catalog: \(entries.count) windows from \(appsScanned) apps"
            + " in \(elapsed)ms, AX enriched \(axByWindowID.count)"
        if skippedSpaceless > 0 { summary += ", \(skippedSpaceless) spaceless skipped" }
        if !axFailures.isEmpty {
            summary += "; AX errors: \(axFailures.joined(separator: " "))"
        }
        WorkspaceLog.write(summary)
        return entries
    }

    /// Fresh AX lookup for one window. Succeeds only while the window's
    /// Space is active (or the window is minimized) — the AX visibility rule.
    func axWindow(for windowID: UInt32, pid: pid_t) -> WorkspaceAXWindow? {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }
        for element in axWindows where self.windowID(of: element) == windowID {
            return WorkspaceAXWindow(element: element)
        }
        return nil
    }

    func cgBounds(of windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowNumber as String] as? UInt32) == windowID {
            guard let dict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            return CGRect(dictionaryRepresentation: dict as CFDictionary)
        }
        return nil
    }

    private func windowID(of element: AXUIElement) -> UInt32? {
        guard let axGetWindow else { return nil }
        var windowID: UInt32 = 0
        guard axGetWindow(element, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    /// Global window-server order across all Spaces; per-Space slices are the
    /// stacking source for capture and the undo snapshot.
    func allWindowIDsFrontToBack() -> [UInt32] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID)
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
