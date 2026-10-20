import CoreAudio
import XCTest
@testable import Witness

final class SystemAudioCaptureTests: XCTestCase {
    func testPermissionServiceNormalizesDeniedStatus() {
        XCTAssertThrowsError(try LiveSystemAudioPermissionService().startCapture { kAudioDevicePermissionsError }) {
            XCTAssertEqual($0 as? SystemAudioPermissionError, .denied)
        }
    }

    func testPermissionServicePreservesOtherCoreAudioStatus() {
        let status = OSStatus(-50)
        XCTAssertThrowsError(try LiveSystemAudioPermissionService().startCapture { status }) {
            XCTAssertEqual($0 as? SystemAudioCaptureError, .coreAudio(status))
        }
    }

    func testPermissionServiceAcceptsSuccessfulStart() {
        XCTAssertNoThrow(try LiveSystemAudioPermissionService().startCapture { noErr })
    }

    func testUnknownProcessDoesNotRequestPermission() {
        let permission = FakeSystemAudioPermission()
        let capture = SystemAudioCapture(resolver: EmptyMeetingProcessResolver(), permission: permission)
        XCTAssertThrowsError(try capture.start(processID: 123)) {
            XCTAssertEqual($0 as? SystemAudioCaptureError, .processNotFound)
        }
        XCTAssertEqual(permission.requestCount, 0)
        capture.stop()
        capture.stop()
    }
}

private struct EmptyMeetingProcessResolver: MeetingProcessResolving {
    func processes() throws -> [MeetingAudioProcess] { [] }
}

private final class FakeSystemAudioPermission: SystemAudioPermissionService, @unchecked Sendable {
    private(set) var requestCount = 0
    func startCapture(_ operation: @Sendable () -> OSStatus) throws {
        requestCount += 1
        let status = operation()
        if status != noErr { throw SystemAudioCaptureError.coreAudio(status) }
    }
}
