import Carbon
import AppKit

/// Carbon walks installed handlers until one returns `noErr`. A handler must
/// explicitly decline hotkeys registered by another `HotKey` instance.
func hotKeyRoutingResult(registered: EventHotKeyID, pressed: EventHotKeyID) -> OSStatus {
    registered.signature == pressed.signature && registered.id == pressed.id
        ? OSStatus(noErr)
        : OSStatus(eventNotHandledErr)
}

/// Global hotkey via Carbon — works without extra permissions.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void
    private let hotKeyID: EventHotKeyID

    init?(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.hotKeyID = EventHotKeyID(signature: OSType(0x474C4244), id: id) // 'GLBD'

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
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
            DispatchQueue.main.async { me.handler() }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
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
