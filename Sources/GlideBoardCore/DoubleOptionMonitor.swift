import CoreGraphics
import Foundation

/// Observes the double-Option gesture through a listen-only session event
/// tap. It never consumes events — Option symbols, ⌥ shortcuts and every
/// existing hotkey keep working — and it is deliberately separate from the
/// Tab-claiming `KeyInterceptor`.
/// Requires the Accessibility permission; creation fails until it's granted,
/// so callers should retry lazily.
final class DoubleOptionMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector: DoubleOptionDetector
    private var optionIsDown = false
    private let isEnabled: () -> Bool
    private let onTrigger: () -> Void

    init?(window: TimeInterval,
          isEnabled: @escaping () -> Bool,
          onTrigger: @escaping () -> Void)
    {
        detector = DoubleOptionDetector(
            config: DoubleOptionDetector.Config(window: window, maxHold: window))
        self.isEnabled = isEnabled
        self.onTrigger = onTrigger

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<DoubleOptionMonitor>.fromOpaque(userData)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                me.observe(type: type, event: event)
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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    private func observe(type: CGEventType, event: CGEvent) {
        var triggered = false
        switch type {
        case .keyDown:
            _ = detector.ingest(.keyDown)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            _ = detector.ingest(.mouseDown)
        case .flagsChanged:
            let flags = event.flags
            let hasOption = flags.contains(.maskAlternate)
            if hasOption != optionIsDown {
                optionIsDown = hasOption
                let now = ProcessInfo.processInfo.systemUptime
                triggered = detector.ingest(
                    hasOption ? .optionDown(at: now) : .optionUp(at: now))
            }
            if !flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty {
                _ = detector.ingest(.otherModifier)
                triggered = false
            }
        default:
            break
        }
        guard triggered else { return }
        // Don't do work inside the tap callback; check the setting at fire
        // time so disabling it in Settings takes effect immediately.
        DispatchQueue.main.async { [isEnabled, onTrigger] in
            if isEnabled() { onTrigger() }
        }
    }
}
