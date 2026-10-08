import AVFoundation
import CoreAudio
import XCTest
@testable import Witness

/// Capture opens a real microphone, so these tests exercise everything that
/// happens *before* the audio unit is touched, through the injected
/// `AudioHardware`. Nothing here raises a permission dialog.
final class HALInputCaptureServiceTests: XCTestCase {
    private struct FakeHardware: AudioHardware {
        var devices: [SystemAudioInput.Device] = []
        var defaultID: AudioDeviceID?
        var channelCounts: [AudioDeviceID: Int] = [:]
        var sampleRates: [AudioDeviceID: Double] = [:]
        var dead: Set<AudioDeviceID> = []

        func defaultInputDeviceID() -> AudioDeviceID? { defaultID }
        func availableInputDevices() -> [SystemAudioInput.Device] { devices }
        func inputChannelCount(of device: AudioDeviceID) -> Int? { channelCounts[device] }
        func nominalSampleRate(of device: AudioDeviceID) -> Double? { sampleRates[device] }
        func isAlive(_ device: AudioDeviceID) -> Bool { !dead.contains(device) }

        // No device is ever opened in these tests, so nothing is observed.
        func addListener(
            object: AudioObjectID,
            selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope,
            queue: DispatchQueue,
            handler: @escaping @Sendable () -> Void
        ) -> AudioPropertyListenerToken? { nil }

        func removeListener(_ token: AudioPropertyListenerToken) {}
    }

    private func device(
        id: AudioDeviceID,
        uid: String,
        name: String,
        transport: UInt32 = kAudioDeviceTransportTypeBuiltIn
    ) -> SystemAudioInput.Device {
        SystemAudioInput.Device(
            id: id,
            uid: uid,
            name: name,
            transportType: transport,
            nominalSampleRate: 48_000
        )
    }

    func testStartWithoutAnyInputDeviceReportsNoInputDevice() async {
        let service = HALInputCaptureService(hardware: FakeHardware())

        do {
            _ = try await service.start(configuration: .default) { _ in }
            XCTFail("Capture must not start without an input device")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .noInputDevice)
        }
    }

    func testStoppingWhenNothingIsRecordingReturnsNothing() async {
        let service = HALInputCaptureService(hardware: FakeHardware())
        let utterance = await service.stop(reason: .hotkeyRelease)
        XCTAssertNil(utterance)
    }

    func testSnapshotWithoutARecordingIsEmpty() {
        let service = HALInputCaptureService(hardware: FakeHardware())
        XCTAssertEqual(service.snapshot().frameCount, 0)
    }

    /// `systemDefault` has to resolve to a concrete device before the unit is
    /// built: leaving the device unset is what made Core Audio create the
    /// aggregate clocked by the speakers.
    func testSystemDefaultResolvesToAConcreteDevice() {
        let builtIn = device(id: 1, uid: "built-in", name: "MacBook Pro Microphone")
        let usb = device(id: 2, uid: "usb", name: "USB Microphone", transport: kAudioDeviceTransportTypeUSB)
        let hardware = FakeHardware(devices: [builtIn, usb], defaultID: 2)

        let resolution = SystemAudioInput.resolve(
            .systemDefault,
            among: hardware.availableInputDevices(),
            defaultID: hardware.defaultInputDeviceID()
        )

        XCTAssertEqual(resolution?.device.id, 2)
        XCTAssertEqual(resolution?.usedFallback, false)
    }

    /// The unit tests above stop before the audio unit is touched, so nothing in
    /// them would catch a wrong `EnableIO` element, a client format the device
    /// rejects, or a channel map that silences the input. This one opens the real
    /// microphone — but only when permission was already granted, so it never
    /// raises a dialog; it is skipped everywhere else.
    func testRealMicrophoneDeliversFramesThroughTheAudioUnit() async throws {
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "Microphone access is not already granted; skipped rather than prompting"
        )
        try XCTSkipUnless(
            SystemAudioInput.resolve(.systemDefault) != nil,
            "No input device on this machine"
        )

        let service = HALInputCaptureService()
        let format = try await service.start(configuration: .default) { _ in }

        XCTAssertGreaterThan(format.inputSampleRate, 0)
        XCTAssertGreaterThan(format.inputChannelCount, 0)
        XCTAssertEqual(format.outputSampleRate, 16_000)
        XCTAssertEqual(format.outputChannelCount, 1)

        try await Task.sleep(for: .milliseconds(600))
        let stopped = await service.stop(reason: .hotkeyRelease)
        let utterance = try XCTUnwrap(stopped)

        // A silent room still produces frames; only a broken configuration
        // produces none.
        XCTAssertGreaterThan(
            utterance.frameCount, 3_000,
            "600 ms at 16 kHz must reach the sink; no frames means the unit never rendered"
        )
        XCTAssertEqual(utterance.droppedFrameCount, 0)
    }

    func testBuiltInSelectionIgnoresANonBuiltInDefault() {
        let builtIn = device(id: 1, uid: "built-in", name: "MacBook Pro Microphone")
        let usb = device(id: 2, uid: "usb", name: "USB Microphone", transport: kAudioDeviceTransportTypeUSB)
        let hardware = FakeHardware(devices: [builtIn, usb], defaultID: 2)

        let resolution = SystemAudioInput.resolve(
            .builtIn,
            among: hardware.availableInputDevices(),
            defaultID: hardware.defaultInputDeviceID()
        )

        XCTAssertEqual(resolution?.device.id, 1)
        XCTAssertEqual(resolution?.usedFallback, false)
    }
}
