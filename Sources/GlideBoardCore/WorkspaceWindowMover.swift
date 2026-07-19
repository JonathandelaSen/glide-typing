import AppKit
import ApplicationServices

/// Space switching and cross-Space window moves through real user gestures:
/// a synthetic click on Mission Control's Spaces bar switches Space, and a
/// synthetic title-bar drag pinned against a screen edge carries a window to
/// the neighbor Space. Every CGS mutation API is a silent no-op for other
/// apps' windows on this macOS build (probe evidence 2026-07-18, see
/// docs/plans/evidence/), so gestures are the only stock-safe mechanism.
/// Every outcome is verified through read-only queries before reporting ok.
@MainActor
final class WorkspaceWindowMover {
    private let spaceManager: SpaceManaging
    private let catalog: WorkspaceWindowCatalog
    /// The grab offset (relative to the window origin) that engaged last
    /// time, per bundle — custom chromes differ (Spotify's center is a
    /// search field, ChatGPT's zoom-adjacent strip is dead), so the winner
    /// goes first on retries.
    private var grabHintByBundle: [String: CGPoint] = [:]

    init(spaceManager: SpaceManaging, catalog: WorkspaceWindowCatalog) {
        self.spaceManager = spaceManager
        self.catalog = catalog
    }

    /// Drag grab point. The strip just right of the zoom (green) button is
    /// draggable chrome in practically every app, including custom title
    /// bars (Spotify's search field famously occupies the geometric center);
    /// without a zoom button, fall back to a conservative title-bar inset.
    static func grabPoint(for frame: CGRect, zoomButton: CGRect?) -> CGPoint {
        if let zoom = zoomButton, frame.contains(CGPoint(x: zoom.midX, y: zoom.midY)) {
            return CGPoint(x: zoom.maxX + 18, y: zoom.midY)
        }
        let inset = min(140, max(40, frame.width * 0.25))
        return CGPoint(x: frame.minX + inset, y: frame.minY + 12)
    }

    // MARK: - Space switching (Mission Control click)

    func switchToOrdinal(_ ordinal: Int, displayUUID: String,
                         spaceIDs: [UInt64]) async -> Bool {
        guard ordinal >= 1, ordinal <= spaceIDs.count else { return false }
        let target = spaceIDs[ordinal - 1]
        if spaceManager.currentSpaceID(displayUUID: displayUUID) == target {
            return true
        }
        WorkspaceLog.write("mover: switch to Space \(ordinal) (id \(target))")
        guard let buttonFrame = await liveSpaceButtonFrame(ordinal: ordinal) else {
            WorkspaceLog.write("mover: Space button \(ordinal) never became clickable")
            escapeMissionControl()
            return false
        }
        click(at: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY))
        let arrived = await poll(timeout: 5) {
            self.spaceManager.currentSpaceID(displayUUID: displayUUID) == target
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if !arrived {
            WorkspaceLog.write("mover: switch to Space \(ordinal) did not arrive")
            escapeMissionControl()
        }
        return arrived
    }

    // MARK: - Dock "Assign To This Desktop"

    /// The app's Desktop pin from the Dock's preferences (a Space UUID), or
    /// nil when unpinned. Read-only: mutations only ever go through the real
    /// Dock menu.
    func dockAssignment(bundleID: String) -> String? {
        CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
        guard let bindings = CFPreferencesCopyValue(
            "app-bindings" as CFString, "com.apple.spaces" as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: String]
        else { return nil }
        return bindings[bundleID.lowercased()] ?? bindings[bundleID]
    }

    /// Moves every window of an app to the CURRENT Space through the Dock
    /// icon's Options menu — a real menu command, no dragging. Only safe
    /// when the caller has checked that all of the app's windows belong on
    /// this Space. The LIVE menu marks decide the flow (preference reads can
    /// be stale): an unpinned app is assigned and unpinned again; an app the
    /// user pinned to THIS Space gets its pin cycled off and on so the
    /// windows gather while the pin ends exactly as the user left it; a pin
    /// to any other Desktop aborts so the caller falls back to dragging.
    func assignAppToCurrentSpace(appName: String, bundleID: String,
                                 jobWindowIDs: [UInt32],
                                 displayUUID: String) async -> String? {
        guard let current = spaceManager.currentSpaceID(displayUUID: displayUUID) else {
            return "The current Space is unknown"
        }
        guard let item = dockItem(named: appName) else {
            return "\(appName) has no Dock icon"
        }
        guard AXUIElementPerformAction(item, "AXShowMenu" as CFString) == .success else {
            return "The Dock menu did not open"
        }
        let optionsShown = await poll(timeout: 2) {
            self.menuItem(under: item, titled: ["Este escritorio", "This Desktop"]) != nil
        }
        guard optionsShown,
              let assignItem = menuItem(under: item,
                                        titled: ["Este escritorio", "This Desktop"]),
              let noneItem = menuItem(under: item, titled: ["Ninguno", "None"]) else {
            escapeKey()
            return "The Dock menu lacks the Assign To options"
        }
        let pinnedHere = menuItemMark(assignItem) != nil
        let unpinned = menuItemMark(noneItem) != nil
        guard pinnedHere || unpinned else {
            escapeKey()
            return "\(appName) is pinned to another Desktop"
        }
        if pinnedHere {
            // Re-pressing a checked "This Desktop" is a no-op, so the gather
            // needs a real state change: unpin, then pin again.
            guard AXUIElementPerformAction(noneItem, kAXPressAction as CFString)
                == .success else {
                escapeKey()
                return "Could not cycle the existing Desktop pin"
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            _ = AXUIElementPerformAction(item, "AXShowMenu" as CFString)
            let reshown = await poll(timeout: 2) {
                self.menuItem(under: item,
                              titled: ["Este escritorio", "This Desktop"]) != nil
            }
            guard reshown, let assignAgain = menuItem(
                under: item, titled: ["Este escritorio", "This Desktop"]) else {
                escapeKey()
                return "The Dock menu vanished while cycling the pin"
            }
            guard AXUIElementPerformAction(assignAgain, kAXPressAction as CFString)
                == .success else {
                escapeKey()
                return "Re-pinning to this Desktop failed"
            }
        } else {
            guard AXUIElementPerformAction(assignItem, kAXPressAction as CFString)
                == .success else {
                escapeKey()
                return "Pressing 'This Desktop' failed"
            }
        }
        let arrived = await poll(timeout: 4) {
            jobWindowIDs.allSatisfy { self.spaceManager.spaceID(ofWindow: $0) == current }
        }
        if !pinnedHere {
            // The Dock rebuilds its item after gathering the windows, so the
            // unpin needs a fresh element each try and a verified result.
            var cleared = false
            for _ in 0..<3 {
                guard let freshItem = dockItem(named: appName) else { break }
                _ = AXUIElementPerformAction(freshItem, "AXShowMenu" as CFString)
                let reopened = await poll(timeout: 2) {
                    self.menuItem(under: freshItem, titled: ["Ninguno", "None"]) != nil
                }
                if reopened,
                   let none = menuItem(under: freshItem, titled: ["Ninguno", "None"]) {
                    _ = AXUIElementPerformAction(none, kAXPressAction as CFString)
                } else {
                    escapeKey()
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
                if dockAssignment(bundleID: bundleID) == nil {
                    cleared = true
                    break
                }
            }
            if !cleared {
                WorkspaceLog.write("mover: WARNING — could not clear the Desktop "
                    + "pin for \(appName); remove it via its Dock icon › Options")
            }
        }
        guard arrived else {
            return "\(appName)'s windows did not arrive via Dock assignment"
        }
        WorkspaceLog.write("mover: \(appName) assigned to the current Space "
            + "(\(jobWindowIDs.count) window(s))"
            + (pinnedHere ? ", user pin kept" : " and unpinned"))
        return nil
    }

    private func dockItem(named name: String) -> AXUIElement? {
        guard let dock = dockElement() else { return nil }
        func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 4 else { return nil }
            if axString(element, kAXRoleAttribute) == "AXDockItem",
               axString(element, kAXTitleAttribute) == name {
                return element
            }
            for child in axChildren(element) {
                if let found = walk(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk(dock, depth: 0)
    }

    private func menuItem(under root: AXUIElement, titled titles: [String],
                          depth: Int = 0) -> AXUIElement? {
        guard depth < 6 else { return nil }
        if axString(root, kAXRoleAttribute) == "AXMenuItem",
           let title = axString(root, kAXTitleAttribute), titles.contains(title) {
            return root
        }
        for child in axChildren(root) {
            if let found = menuItem(under: child, titled: titles, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func menuItemMark(_ item: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, "AXMenuItemMarkChar" as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Cross-Space carry (edge-pinned drag)

    /// The window must be on the ACTIVE Space. Steps toward the target one
    /// neighbor at a time, re-deriving direction from the verified current
    /// ordinal, so fullscreen tiles or a missed slide never desynchronize it.
    func carryWindow(_ windowID: UInt32, pid: pid_t, toOrdinal: Int,
                     displayUUID: String, spaceIDs: [UInt64]) async -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return "The owning app is gone"
        }
        let bundleID = app.bundleIdentifier ?? ""
        // The app's AX window list refreshes up to a second after a Space
        // switch; poll instead of trusting the first read.
        var lookup: WorkspaceAXWindow?
        _ = await poll(timeout: 2.5) {
            lookup = self.catalog.axWindow(for: windowID, pid: pid)
            return lookup != nil
        }
        guard let axWindow = lookup else {
            return "AX cannot reach the window on the active Space"
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            app.activate()
            _ = await poll(timeout: 1.0) {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }
        }
        axWindow.raise()
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let frame = axWindow.frame() else {
            return "The window frame is unreadable"
        }

        let display = CGDisplayBounds(CGMainDisplayID())
        let zoomButton = axWindow.zoomButtonFrame()
        var candidates: [CGPoint] = []
        if let hint = grabHintByBundle[bundleID] {
            candidates.append(CGPoint(x: frame.origin.x + hint.x,
                                      y: frame.origin.y + hint.y))
        }
        candidates.append(contentsOf: dragSafePoints(for: frame, zoomButton: zoomButton))
        candidates.append(Self.grabPoint(for: frame, zoomButton: zoomButton))
        candidates.append(Self.grabPoint(for: frame, zoomButton: nil))
        candidates.append(CGPoint(x: frame.midX, y: frame.minY + 12))
        var deduped: [CGPoint] = []
        for point in candidates
            where !deduped.contains(where: { abs($0.x - point.x) < 4
                && abs($0.y - point.y) < 4 }) {
            deduped.append(point)
        }
        candidates = Array(deduped.prefix(5))
        var cursor = CGPoint.zero
        var engaged = false
        for (attempt, grab) in candidates.enumerated() {
            WorkspaceLog.write("mover: grab attempt \(attempt + 1) at "
                + "(\(Int(grab.x)),\(Int(grab.y)))")
            mouse(.mouseMoved, grab)
            try? await Task.sleep(nanoseconds: 150_000_000)
            mouse(.leftMouseDown, grab)
            try? await Task.sleep(nanoseconds: 200_000_000)
            cursor = grab
            for step in 1...4 {
                cursor = CGPoint(x: grab.x + CGFloat(step) * 6,
                                 y: grab.y + CGFloat(step) * 4)
                mouse(.leftMouseDragged, cursor)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            if let moved = catalog.cgBounds(of: windowID),
               abs(moved.origin.x - frame.origin.x)
                   + abs(moved.origin.y - frame.origin.y) > 8 {
                engaged = true
                grabHintByBundle[bundleID] = CGPoint(x: grab.x - frame.origin.x,
                                                     y: grab.y - frame.origin.y)
                break
            }
            mouse(.leftMouseUp, cursor)
            try? await Task.sleep(nanoseconds: 250_000_000)
            // The failed press may have landed in a control (Spotify's
            // search field); ESC clears any focus or popup it caused.
            escapeKey()
            WorkspaceLog.write("mover: drag engage attempt \(attempt + 1) failed "
                + "for window \(windowID)")
        }
        guard engaged else { return "The window drag never engaged" }

        func currentOrdinal() -> Int? {
            spaceManager.currentSpaceID(displayUUID: displayUUID)
                .flatMap { spaceIDs.firstIndex(of: $0) }
                .map { $0 + 1 }
        }
        let pinY = min(max(cursor.y, display.minY + 60), display.minY + 500)
        var iterations = 0
        while currentOrdinal() != toOrdinal {
            iterations += 1
            guard iterations <= spaceIDs.count + 4 else {
                drop(at: CGPoint(x: display.midX, y: pinY + 200))
                return "Lost track of the Space while carrying the window"
            }
            guard let ordinalNow = currentOrdinal() else {
                drop(at: CGPoint(x: display.midX, y: pinY + 200))
                return "The current Space is not a user Space"
            }
            let goRight = toOrdinal > ordinalNow
            // The slide only triggers on the boundary pixel itself: maxX - 1
            // on the right, minX (not minX + 1) on the left.
            let edge = CGPoint(x: goRight ? display.maxX - 1 : display.minX,
                               y: pinY)
            let spaceBefore = spaceManager.currentSpaceID(displayUUID: displayUUID)
            for step in 1...6 {
                let t = CGFloat(step) / 6
                mouse(.leftMouseDragged,
                      CGPoint(x: cursor.x + (edge.x - cursor.x) * t, y: pinY))
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            var switched = false
            var held = 0.0
            while held < 3.5 {
                mouse(.leftMouseDragged, CGPoint(
                    x: edge.x,
                    y: pinY + (held * 10).truncatingRemainder(dividingBy: 3)))
                try? await Task.sleep(nanoseconds: 120_000_000)
                held += 0.12
                if spaceManager.currentSpaceID(displayUUID: displayUUID) != spaceBefore {
                    switched = true
                    break
                }
            }
            let retreat = CGPoint(x: goRight ? display.maxX - 420 : display.minX + 420,
                                  y: pinY)
            mouse(.leftMouseDragged, retreat)
            cursor = retreat
            guard switched else {
                drop(at: CGPoint(x: display.midX, y: pinY + 200))
                return "The Space did not slide at the screen edge"
            }
            WorkspaceLog.write("mover: carried window \(windowID) one Space "
                + (goRight ? "right" : "left") + ", now ordinal "
                + "\(currentOrdinal().map(String.init) ?? "?")")
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        drop(at: CGPoint(x: display.midX, y: pinY + 200))
        let landed = await poll(timeout: 2) {
            self.spaceManager.spaceID(ofWindow: windowID) == spaceIDs[toOrdinal - 1]
        }
        guard landed else {
            let now = spaceManager.spaceID(ofWindow: windowID)
            return "The window landed on space id "
                + "\(now.map(String.init) ?? "?") instead of Space \(toOrdinal)"
        }
        return nil
    }

    /// Hit-tests a spread of title-area points and keeps only those landing
    /// on inert chrome: grabbing a button focuses it (Spotify's search bar)
    /// and grabbing a tab tears it off (Brave), so interactive roles are
    /// rejected before any mouse button goes down. The engage check remains
    /// the final arbiter.
    private func dragSafePoints(for frame: CGRect,
                                zoomButton: CGRect?) -> [CGPoint] {
        let systemWide = AXUIElementCreateSystemWide()
        let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXSearchField", "AXTextArea",
            "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider",
            "AXMenuButton", "AXComboBox", "AXLink", "AXTab", "AXTabGroup",
            "AXDisclosureTriangle", "AXIncrementor", "AXSegmentedControl",
            "AXScrollBar",
        ]
        var rows: [CGFloat] = [frame.minY + 12]
        if let zoom = zoomButton { rows.insert(zoom.midY, at: 0) }
        rows.append(frame.minY + 45)
        var columns: [CGFloat] = []
        if let zoom = zoomButton {
            columns.append(zoom.maxX + 18)
            columns.append(zoom.maxX + 90)
        }
        columns.append(contentsOf: [0.25, 0.4, 0.55, 0.7, 0.85]
            .map { frame.minX + frame.width * $0 })
        var safe: [CGPoint] = []
        for y in rows {
            for x in columns {
                let point = CGPoint(x: x, y: y)
                guard frame.contains(point), safe.count < 4 else { continue }
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    systemWide, Float(point.x), Float(point.y),
                    &element) == .success, let element else { continue }
                let role = axString(element, kAXRoleAttribute) ?? ""
                if !interactiveRoles.contains(role) {
                    safe.append(point)
                }
            }
        }
        return safe
    }

    // MARK: - Mission Control via the Dock's AX tree

    private func dockElement() -> AXUIElement? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }

    private func axFrame(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeValue) == .success else { return .zero }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func missionControlGroup() -> AXUIElement? {
        guard let dock = dockElement() else { return nil }
        return axChildren(dock).first {
            axString($0, kAXRoleAttribute) == "AXGroup"
                && axString($0, kAXTitleAttribute) == "Mission Control"
        }
    }

    /// Space buttons carry a trailing desktop number in every locale
    /// ("Escritorio 3", "Desktop 3"); a live one has an on-screen expanded
    /// frame. A stale Mission Control group can outlive the closed overlay
    /// with zero-frame children, so liveness comes only from the frames.
    private func liveSpaceButtonFrames() -> [Int: CGRect] {
        guard let group = missionControlGroup() else { return [:] }
        var frames: [Int: CGRect] = [:]
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 8 else { return }
            if axString(element, kAXRoleAttribute) == kAXButtonRole as String,
               let title = axString(element, kAXTitleAttribute),
               let number = title.split(separator: " ").last.flatMap({ Int($0) }) {
                let frame = axFrame(element)
                if frame.origin.y >= 0 && frame.height > 30 && frame.width > 60 {
                    frames[number] = frame
                }
            }
            for child in axChildren(element) {
                walk(child, depth: depth + 1)
            }
        }
        walk(group, depth: 0)
        return frames
    }

    private func liveSpaceButtonFrame(ordinal: Int) async -> CGRect? {
        let display = CGDisplayBounds(CGMainDisplayID())
        let hover = CGPoint(x: display.midX, y: display.minY + 6)
        mouse(.mouseMoved, hover)
        var launched = false
        var waited = 0.0
        while waited < 6 {
            if let frame = liveSpaceButtonFrames()[ordinal] {
                return frame
            }
            if !launched && waited >= 1.2 {
                launched = true
                openMissionControl()
                mouse(.mouseMoved, hover)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }
        return nil
    }

    private func openMissionControl() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Mission Control"]
        try? task.run()
        task.waitUntilExit()
    }

    private func escapeMissionControl() {
        guard !liveSpaceButtonFrames().isEmpty else { return }
        escapeKey()
    }

    private func escapeKey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?
                .post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Event synthesis

    private func mouse(_ type: CGEventType, _ point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        if type == .leftMouseDown || type == .leftMouseDragged {
            event?.setDoubleValueField(.mouseEventPressure, value: 1)
        }
        event?.post(tap: .cgSessionEventTap)
    }

    private func click(at point: CGPoint) {
        mouse(.mouseMoved, point)
        usleep(120_000)
        mouse(.leftMouseDown, point)
        usleep(90_000)
        mouse(.leftMouseUp, point)
    }

    private func drop(at point: CGPoint) {
        mouse(.leftMouseDragged, point)
        usleep(90_000)
        mouse(.leftMouseUp, point)
    }

    private func poll(timeout: TimeInterval,
                      _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return condition()
    }
}
