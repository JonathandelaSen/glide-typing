import Carbon
import AppKit

/// Carbon walks installed handlers until one returns `noErr`. A handler must
/// explicitly decline hotkeys registered by another `HotKey` instance.
func hotKeyRoutingResult(registered: EventHotKeyID, pressed: EventHotKeyID) -> OSStatus {
    registered.signature == pressed.signature && registered.id == pressed.id
        ? OSStatus(noErr)
        : OSStatus(eventNotHandledErr)
}

enum HotKeyPhase: Equatable {
    case pressed
    case released
}

func hotKeyPhase(eventKind: UInt32) -> HotKeyPhase? {
    switch eventKind {
    case UInt32(kEventHotKeyPressed): return .pressed
    case UInt32(kEventHotKeyReleased): return .released
    default: return nil
    }
}

/// Global hotkey via Carbon — works without extra permissions.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let pressedHandler: () -> Void
    private let releasedHandler: (() -> Void)?
    private let hotKeyID: EventHotKeyID

    convenience init?(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                      handler: @escaping () -> Void)
    {
        self.init(id: id, keyCode: keyCode, modifiers: modifiers,
                  pressed: handler, released: nil)
    }

    init?(id: UInt32, keyCode: UInt32, modifiers: UInt32,
          pressed: @escaping () -> Void, released: (() -> Void)?)
    {
        self.pressedHandler = pressed
        self.releasedHandler = released
        self.hotKeyID = EventHotKeyID(signature: OSType(0x474C4244), id: id) // 'GLBD'

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed))
        ]
        if released != nil {
            eventTypes.append(EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                            eventKind: UInt32(kEventHotKeyReleased)))
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressedID = EventHotKeyID()
            let readStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            guard readStatus == noErr else { return OSStatus(eventNotHandledErr) }
            let routingResult = hotKeyRoutingResult(registered: me.hotKeyID, pressed: pressedID)
            guard routingResult == noErr else { return routingResult }
            guard let phase = hotKeyPhase(eventKind: GetEventKind(event)) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                switch phase {
                case .pressed: me.pressedHandler()
                case .released: me.releasedHandler?()
                }
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPtr, &eventHandler)
        guard status == noErr else { return nil }

        let reg = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        guard reg == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
