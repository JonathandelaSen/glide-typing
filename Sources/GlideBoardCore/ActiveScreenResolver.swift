import AppKit
import ApplicationServices
import Foundation

enum OverlayPositioner {
    static func origin(visibleFrame: CGRect, panelSize: CGSize) -> CGPoint {
        CGPoint(x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + 26)
    }
}

enum NumaSignalLevel {
    static func normalized(rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 0.000_001))
        return CGFloat(min(1, max(0, (db + 60) / 50)))
    }
}

enum ActiveScreenResolver {
    static func resolve(lastExternalApp: NSRunningApplication?) -> NSScreen? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let candidate = frontmost?.processIdentifier == ownPID ? lastExternalApp : frontmost
        if let candidate, let center = focusedWindowCenter(in: candidate),
           let index = screenIndex(containing: center, frames: NSScreen.screens.map(\.frame)) {
            return NSScreen.screens[index]
        }
        if let index = screenIndex(containing: NSEvent.mouseLocation,
                                   frames: NSScreen.screens.map(\.frame)) {
            return NSScreen.screens[index]
        }
        return NSScreen.main
    }

    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    private static func focusedWindowCenter(in app: NSRunningApplication) -> CGPoint? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: position.x + size.width / 2,
                       y: primaryTop - (position.y + size.height / 2))
    }
}
