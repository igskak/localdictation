import CoreAudio
import XCTest
@testable import Witness

final class MeetingMicrophoneCaptureTests: XCTestCase {
    func testDeniedMicrophoneDoesNotRequestAccessOrOpenHardware() {
        let permission = FakeMicrophonePermissionService(authorization: .denied)
        let capture = MeetingMicrophoneCapture(permission: permission)
        XCTAssertThrowsError(try capture.start(selection: .systemDefault)) {
            XCTAssertEqual($0 as? MeetingMicrophoneError, .permissionUnavailable)
        }
        XCTAssertEqual(permission.requestCount, 0)
        capture.stop()
        capture.stop()
    }

    func testEveryUnavailablePermissionStateAvoidsTheHardwareAndPrompt() {
        for authorization in [MicrophoneAuthorization.notDetermined, .denied, .restricted] {
            let permission = FakeMicrophonePermissionService(authorization: authorization)
            let capture = MeetingMicrophoneCapture(hardware: EmptyMeetingAudioHardware(), permission: permission)
            XCTAssertThrowsError(try capture.start(selection: .systemDefault)) {
                XCTAssertEqual($0 as? MeetingMicrophoneError, .permissionUnavailable)
            }
            XCTAssertEqual(permission.requestCount, 0)
        }
    }

    func testAuthorizedCaptureReportsMissingInputWithoutOpeningAnAudioUnit() {
        let permission = FakeMicrophonePermissionService(authorization: .authorized)
        let capture = MeetingMicrophoneCapture(hardware: EmptyMeetingAudioHardware(), permission: permission)
        XCTAssertThrowsError(try capture.start(selection: .systemDefault)) {
            XCTAssertEqual($0 as? MeetingMicrophoneError, .noInput)
        }
        XCTAssertEqual(permission.requestCount, 0)
    }
}

private struct EmptyMeetingAudioHardware: AudioHardware {
    func defaultInputDeviceID() -> AudioDeviceID? { nil }
    func availableInputDevices() -> [SystemAudioInput.Device] { [] }
    func inputChannelCount(of device: AudioDeviceID) -> Int? { nil }
    func nominalSampleRate(of device: AudioDeviceID) -> Double? { nil }
    func isAlive(_ device: AudioDeviceID) -> Bool { false }
    func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope, queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) -> AudioPropertyListenerToken? { nil }
    func removeListener(_ token: AudioPropertyListenerToken) {}
}
