import XCTest
@testable import LocalDictation

final class StatusPresentationTests: XCTestCase {
    private let binding = HotkeyBinding.optionSpace

    func testDefaultBindingIsOptionSpace() {
        XCTAssertEqual(binding.displayString, "⌥Space")
        XCTAssertEqual(binding.keyCode, 49)
        XCTAssertEqual(binding.modifiers, .option)
    }

    func testReadyStateTellsTheUserWhatToPress() {
        let presentation = StatusPresentation(state: .ready, binding: binding)
        XCTAssertEqual(presentation.title, "Ready")
        XCTAssertTrue(presentation.detail.contains("⌥Space"))
        XCTAssertEqual(presentation.tint, .ready)
        XCTAssertFalse(presentation.showsPermissionRequest)
    }

    func testNotDeterminedOffersAnExplicitRequest() {
        let presentation = StatusPresentation(state: .needsPermission, binding: binding)
        XCTAssertTrue(presentation.showsPermissionRequest)
        XCTAssertFalse(presentation.showsSystemSettingsShortcut)
    }

    func testDeniedRoutesToSystemSettings() {
        let presentation = StatusPresentation(state: .permissionDenied(restricted: false), binding: binding)
        XCTAssertTrue(presentation.showsSystemSettingsShortcut)
        XCTAssertFalse(presentation.showsPermissionRequest)
        XCTAssertEqual(presentation.tint, .warning)
    }

    func testRestrictedExplainsThatTheUserCannotFixItAlone() {
        let presentation = StatusPresentation(state: .permissionDenied(restricted: true), binding: binding)
        XCTAssertEqual(presentation.title, "Microphone access restricted")
        XCTAssertTrue(presentation.detail.lowercased().contains("policy"))
    }

    func testRecordingStateIsVisuallyDistinct() {
        let recording = StatusPresentation(state: .recording, binding: binding)
        let ready = StatusPresentation(state: .ready, binding: binding)

        XCTAssertEqual(recording.tint, .active)
        XCTAssertNotEqual(recording.systemImage, ready.systemImage)
        XCTAssertTrue(recording.detail.contains("⌥Space"))
    }

    func testFailureOffersRecovery() {
        let presentation = StatusPresentation(state: .failed(.hotkeyRegistration("collision")), binding: binding)
        XCTAssertTrue(presentation.showsRecoveryAction)
        XCTAssertTrue(presentation.detail.contains("collision"))
    }
}
