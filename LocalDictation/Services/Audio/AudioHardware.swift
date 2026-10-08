import CoreAudio
import Foundation

/// The Core Audio queries capture needs, behind a protocol.
///
/// Capture asks the hardware three kinds of question: which device to open, what
/// that device currently looks like, and whether it is still there. Keeping them
/// here means the route-change policy can be exercised in tests with a fake, so
/// the suite never opens a microphone or raises a permission dialog.
protocol AudioHardware: Sendable {
    /// The system-wide default input, or `nil` when there is none.
    func defaultInputDeviceID() -> AudioDeviceID?
    /// Every device that currently has input streams and is alive.
    func availableInputDevices() -> [SystemAudioInput.Device]
    /// Channels the device reports on its input scope right now. This is the
    /// number that changes from 1 to 3 when another app starts voice processing.
    func inputChannelCount(of device: AudioDeviceID) -> Int?
    /// The device's nominal sample rate right now.
    func nominalSampleRate(of device: AudioDeviceID) -> Double?
    /// False once the device has gone away under us.
    func isAlive(_ device: AudioDeviceID) -> Bool

    /// Observes one property of one Core Audio object. `handler` runs on
    /// `queue`, never on Core Audio's own listener thread, so it is free to do
    /// work. Returns `nil` when the listener could not be registered.
    func addListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioPropertyListenerToken?

    func removeListener(_ token: AudioPropertyListenerToken)
}

/// Keeps a registered Core Audio property listener removable.
///
/// `AudioObjectRemovePropertyListenerBlock` matches on the block itself, so the
/// block has to outlive the registration.
final class AudioPropertyListenerToken: @unchecked Sendable {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }
}

/// The live implementation, reading the real Core Audio object graph.
struct SystemAudioHardware: AudioHardware {
    func defaultInputDeviceID() -> AudioDeviceID? {
        SystemAudioInput.defaultInputDeviceID()
    }

    func availableInputDevices() -> [SystemAudioInput.Device] {
        SystemAudioInput.availableInputDevices()
    }

    func inputChannelCount(of device: AudioDeviceID) -> Int? {
        SystemAudioInput.inputChannelCount(of: device)
    }

    func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        SystemAudioInput.nominalSampleRate(of: device)
    }

    func isAlive(_ device: AudioDeviceID) -> Bool {
        SystemAudioInput.isAlive(device)
    }

    func addListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioPropertyListenerToken? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return AudioPropertyListenerToken(object: object, address: address, queue: queue, block: block)
    }

    func removeListener(_ token: AudioPropertyListenerToken) {
        var address = token.address
        AudioObjectRemovePropertyListenerBlock(token.object, &address, token.queue, token.block)
    }
}
