import AppKit
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

    private let singleKey = ModifierKeyMonitor()
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
        if binding.isSingleModifier {
            try singleKey.register(binding, handler: handler)
            lock.withLock { self.binding = binding }
            return
        }

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

    func setActivation(_ activation: RecordingActivation) { singleKey.activation = activation }

    func unregister() {
        singleKey.unregister()
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

/// Observes only gesture state. No typed characters or sequences are retained.
private final class ModifierKeyMonitor: @unchecked Sendable {
    var activation: RecordingActivation = .pushToTalk {
        willSet { if activation != newValue { reset(cancel: true); handler?(.cancelled) } }
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var binding: HotkeyBinding?
    private var handler: (@Sendable (HotkeyEvent) -> Void)?
    private var gesture = ModifierKeyGesture()
    private var pending: DispatchWorkItem?
    private var accessFailureReported = false
    private var health: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        guard CGPreflightListenEventAccess() else { throw HotkeyRegistrationError.keyboardAccessRequired }
        self.binding = binding
        self.handler = handler
        accessFailureReported = false
        let observed: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = observed.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.receive(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            unregister()
            throw HotkeyRegistrationError.keyboardAccessRequired
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !CGPreflightListenEventAccess() {
                self.reset(cancel: true)
                if !self.accessFailureReported { self.accessFailureReported = true; self.handler?(.unavailable) }
            } else if IsSecureEventInputEnabled() {
                self.reset(cancel: true)
                self.handler?(.cancelled)
            }
        }
        health = timer; timer.resume()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reset(cancel: true)
                self?.handler?(.cancelled)
            })
        }
    }

    func unregister() {
        handler?(.cancelled)
        reset(cancel: true)
        health?.cancel(); health = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; binding = nil; handler = nil
    }

    private func reset(cancel: Bool) {
        pending?.cancel(); pending = nil
        if gesture.started && cancel { handler?(.cancelled) }
        gesture.reset()
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset(cancel: true)
            handler?(.cancelled)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let binding else { return }
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let base = binding.keyCode & 0xFFFF
        let pairs: [UInt32: UInt32] = [55:54,58:61,59:62,56:60]
        let codes = binding.keyCode > 0xFFFF ? [base, pairs[base] ?? base] : [base]
        let physicalDown = codes.contains { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
        if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) || (type == .flagsChanged && !codes.contains(code)) {
            if gesture.held {
                pending?.cancel()
                if gesture.interfere() { handler?(.cancelled) }
            }
            return
        }
        guard type == .flagsChanged, codes.contains(code) else { return }
        if physicalDown && !gesture.held {
            let relevant = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
            gesture.begin(clean: relevant.rawValue.nonzeroBitCount == 1)
            guard !gesture.invalid, activation == .pushToTalk else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.gesture.activate() else { return }
                self.handler?(.pressed)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else if !physicalDown && gesture.held {
            pending?.cancel()
            if !gesture.invalid {
                if activation == .toggle { handler?(.pressed); handler?(.released) }
                else if gesture.started { handler?(.released) }
            }
            reset(cancel: false)
        }
    }
}
