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

    init(spaceManager: SpaceManaging, catalog: WorkspaceWindowCatalog) {
        self.spaceManager = spaceManager
        self.catalog = catalog
    }

    /// Title-bar grab point: past the traffic lights, well inside the bar.
    static func grabPoint(for frame: CGRect) -> CGPoint {
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
        try? await Task.sleep(nanoseconds: 500_000_000)
        if !arrived {
            WorkspaceLog.write("mover: switch to Space \(ordinal) did not arrive")
            escapeMissionControl()
        }
        return arrived
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
        guard let axWindow = catalog.axWindow(for: windowID, pid: pid) else {
            return "AX cannot reach the window on the active Space"
        }
        app.activate()
        _ = await poll(timeout: 1.5) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        axWindow.raise()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let frame = axWindow.frame() else {
            return "The window frame is unreadable"
        }

        let display = CGDisplayBounds(CGMainDisplayID())
        var cursor = CGPoint.zero
        var engaged = false
        for attempt in 0..<2 {
            let grab = attempt == 0 ? Self.grabPoint(for: frame)
                : CGPoint(x: frame.midX, y: frame.minY + 12)
            mouse(.mouseMoved, grab)
            try? await Task.sleep(nanoseconds: 180_000_000)
            mouse(.leftMouseDown, grab)
            try? await Task.sleep(nanoseconds: 250_000_000)
            cursor = grab
            for step in 1...4 {
                cursor = CGPoint(x: grab.x + CGFloat(step) * 6,
                                 y: grab.y + CGFloat(step) * 4)
                mouse(.leftMouseDragged, cursor)
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let moved = catalog.cgBounds(of: windowID),
               abs(moved.origin.x - frame.origin.x)
                   + abs(moved.origin.y - frame.origin.y) > 8 {
                engaged = true
                break
            }
            mouse(.leftMouseUp, cursor)
            try? await Task.sleep(nanoseconds: 300_000_000)
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
            try? await Task.sleep(nanoseconds: 600_000_000)
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
