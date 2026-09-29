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
}
