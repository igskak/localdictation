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
}
