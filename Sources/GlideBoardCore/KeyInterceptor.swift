import CoreGraphics
import Foundation

/// Session-level event tap that lets the app claim specific physical keys
/// (e.g. Tab to accept the ghost) while the panel is visible — the panel is
/// non-activating, so physical keys otherwise never reach us.
/// Requires the Accessibility permission (already needed for injection);
/// creation fails until it's granted, so callers should retry lazily.
final class KeyInterceptor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Called for every physical key-down (keyCode, flags, isAutorepeat).
    /// Return true to consume the event, false to let it through.
    private let handler: (CGKeyCode, CGEventFlags, Bool) -> Bool

    init?(handler: @escaping (CGKeyCode, CGEventFlags, Bool) -> Bool) {
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyInterceptor>.fromOpaque(userData).takeUnretainedValue()
                // The system disables taps that stall; re-enable and move on.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if me.handler(keyCode, event.flags, isRepeat) { return nil }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr) else { return nil }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    static let tabKey: CGKeyCode = 48
}
