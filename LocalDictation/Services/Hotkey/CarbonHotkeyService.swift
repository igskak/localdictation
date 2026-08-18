import Carbon
import Foundation

/// Global hotkey registration through `RegisterEventHotKey`.
///
/// Carbon's hot key API is used deliberately: it is the only system API that
/// delivers global key-down *and* key-up events — which push-to-talk requires —
/// without asking for Accessibility or Input Monitoring access. A `CGEventTap`
/// would add a permission prompt that Phase 1 explicitly avoids.
///
/// Callbacks are delivered on the main thread because the handler is installed on
/// the application event target, which is serviced by the main run loop.
final class CarbonHotkeyService: HotkeyService, @unchecked Sendable {
    fileprivate static let signature: OSType = 0x4C_44_4B_54 // 'LDKT'
    fileprivate static let identifier: UInt32 = 1

    private let lock = UnfairLock()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (@Sendable (HotkeyEvent) -> Void)?
    private var binding: HotkeyBinding?

    init() {}

    deinit {
        unregister()
    }

    var registeredBinding: HotkeyBinding? {
        lock.withLock { binding }
    }

    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        unregister()

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyEventCallback,
            specs.count,
            &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard installStatus == noErr else {
            throw HotkeyRegistrationError.handlerInstallationFailed(status: installStatus)
        }

        var registeredRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registerStatus = RegisterEventHotKey(
            binding.keyCode,
            Self.carbonModifiers(from: binding.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredRef
        )

        guard registerStatus == noErr, let registeredRef else {
            if let installedHandler {
                RemoveEventHandler(installedHandler)
            }
            if registerStatus == OSStatus(eventHotKeyExistsErr) {
                throw HotkeyRegistrationError.alreadyInUse
            }
            throw HotkeyRegistrationError.registrationFailed(status: registerStatus)
        }

        lock.withLock {
            self.hotKeyRef = registeredRef
            self.eventHandlerRef = installedHandler
            self.handler = handler
            self.binding = binding
        }

        Log.hotkey.info("Registered push-to-talk hotkey \(binding.displayString, privacy: .public)")
    }

    func unregister() {
        let (hotKey, eventHandler, previousBinding): (EventHotKeyRef?, EventHandlerRef?, HotkeyBinding?) = lock.withLock {
            let values = (hotKeyRef, eventHandlerRef, binding)
            hotKeyRef = nil
            eventHandlerRef = nil
            handler = nil
            binding = nil
            return values
        }

        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        if let previousBinding {
            Log.hotkey.info("Unregistered hotkey \(previousBinding.displayString, privacy: .public)")
        }
    }

    fileprivate func deliver(_ event: HotkeyEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    private static func carbonModifiers(from modifiers: HotkeyModifiers) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// C callback trampoline. Runs on the main thread; it only forwards the event so
/// press/release ordering is preserved.
private func carbonHotkeyEventCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == CarbonHotkeyService.signature,
          hotKeyID.id == CarbonHotkeyService.identifier
    else {
        return OSStatus(eventNotHandledErr)
    }

    let service = Unmanaged<CarbonHotkeyService>.fromOpaque(userData).takeUnretainedValue()
    switch Int(GetEventKind(event)) {
    case kEventHotKeyPressed:
        service.deliver(.pressed)
    case kEventHotKeyReleased:
        service.deliver(.released)
    default:
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}
