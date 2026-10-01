import CoreAudio
import Foundation

/// Read-only Core Audio discovery. Reading device metadata does not request
/// microphone access or change the system-wide input/output routing.
enum SystemAudioInput {
    struct Device: Sendable, Equatable, Identifiable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transportType: UInt32
        let nominalSampleRate: Double?

        var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
        /// A headset on the far side of a radio link, which may be shared with
        /// another host and may answer us without its microphone.
        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    struct Resolution: Sendable, Equatable {
        let device: Device
        let usedFallback: Bool
    }

    static func availableInputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(id),
                  isAlive(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
                  let name = stringProperty(kAudioObjectPropertyName, of: id)
            else { return nil }
            return Device(
                id: id,
                uid: uid,
                name: name,
                transportType: scalarProperty(kAudioDevicePropertyTransportType, of: id) ?? kAudioDeviceTransportTypeUnknown,
                nominalSampleRate: nominalSampleRate(of: id)
            )
        }
    }

    static func resolve(_ selection: AudioInputSelection) -> Resolution? {
        resolve(selection, among: availableInputDevices(), defaultID: defaultInputDeviceID())
    }

    /// Pure selection policy, shared by capture and deterministic tests.
    static func resolve(
        _ selection: AudioInputSelection,
        among devices: [Device],
        defaultID: AudioDeviceID?
    ) -> Resolution? {
        let systemDefault = devices.first { $0.id == defaultID }
        let builtIn = devices.first { $0.isBuiltIn && $0.id == defaultID }
            ?? devices.first { $0.isBuiltIn }

        switch selection {
        case .builtIn:
            guard let device = builtIn ?? systemDefault ?? devices.first else { return nil }
            return Resolution(device: device, usedFallback: !device.isBuiltIn)
        case .systemDefault:
            guard let device = systemDefault ?? builtIn ?? devices.first else { return nil }
            return Resolution(device: device, usedFallback: systemDefault == nil)
        case let .device(uid):
            let selected = devices.first { $0.uid == uid }
            guard let device = selected ?? builtIn ?? systemDefault ?? devices.first else { return nil }
            return Resolution(device: device, usedFallback: selected == nil)
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Channels the device currently reports on its input scope.
    ///
    /// Not a fixed property of the hardware: the built-in microphone reports 1
    /// channel normally and 3 raw array channels while another app runs Apple
    /// voice processing, and the change arrives as a property notification.
    static func inputChannelCount(of id: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return nil }

        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioStreamID>.stride
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        scalarProperty(kAudioDevicePropertyDeviceIsAlive, of: id) == 1
    }

    private static func scalarProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    static func nominalSampleRate(of id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}
