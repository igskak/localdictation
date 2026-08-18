import XCTest
@testable import LocalDictation

final class RecordingStateMachineTests: XCTestCase {
    func testAuthorizationMapsToState() {
        XCTAssertEqual(RecordingStateMachine.state(for: .authorized), .ready)
        XCTAssertEqual(RecordingStateMachine.state(for: .notDetermined), .needsPermission)
        XCTAssertEqual(RecordingStateMachine.state(for: .denied), .permissionDenied(restricted: false))
        XCTAssertEqual(RecordingStateMachine.state(for: .restricted), .permissionDenied(restricted: true))
    }

    func testHappyPathPressAndRelease() {
        var machine = RecordingStateMachine()
        XCTAssertTrue(machine.apply(.authorizationResolved(.authorized)).didTransition)
        XCTAssertEqual(machine.state, .ready)

        XCTAssertTrue(machine.apply(.hotkeyPressed).didTransition)
        XCTAssertEqual(machine.state, .starting)

        XCTAssertTrue(machine.apply(.captureStarted).didTransition)
        XCTAssertEqual(machine.state, .recording)

        XCTAssertTrue(machine.apply(.hotkeyReleased).didTransition)
        XCTAssertEqual(machine.state, .finishing)

        XCTAssertTrue(machine.apply(.utteranceCompleted).didTransition)
        XCTAssertEqual(machine.state, .ready)
    }

    func testReleaseBeforeCaptureStartedKeepsFinishingState() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        XCTAssertTrue(machine.apply(.hotkeyReleased).didTransition)
        XCTAssertEqual(machine.state, .finishing)

        // A late `captureStarted` must not move back into `.recording`.
        XCTAssertEqual(machine.apply(.captureStarted), .rejected(.finishing, .captureStarted))
        XCTAssertEqual(machine.state, .finishing)
    }

    func testHotkeyPressIsRejectedWithoutPermission() {
        var machine = RecordingStateMachine(state: .permissionDenied(restricted: false))
        XCTAssertEqual(machine.apply(.hotkeyPressed), .rejected(.permissionDenied(restricted: false), .hotkeyPressed))
        XCTAssertEqual(machine.state, .permissionDenied(restricted: false))

        var undetermined = RecordingStateMachine(state: .needsPermission)
        XCTAssertFalse(undetermined.apply(.hotkeyPressed).didTransition)
        XCTAssertEqual(undetermined.state, .needsPermission)
    }

    func testDoubleReleaseIsRejected() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        machine.apply(.captureStarted)
        machine.apply(.hotkeyReleased)
        XCTAssertFalse(machine.apply(.hotkeyReleased).didTransition)
        XCTAssertEqual(machine.state, .finishing)
    }

    func testMaximumDurationFinishesRecording() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        machine.apply(.captureStarted)
        XCTAssertTrue(machine.apply(.maximumDurationReached).didTransition)
        XCTAssertEqual(machine.state, .finishing)
    }

    func testFailuresAreRecoverable() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        machine.apply(.captureFailed(.captureStart("engine")))
        XCTAssertEqual(machine.state, .failed(.captureStart("engine")))

        XCTAssertTrue(machine.apply(.recoveryRequested).didTransition)
        XCTAssertEqual(machine.state, .ready)
    }

    func testInterruptionWhileRecordingFails() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        machine.apply(.captureStarted)
        XCTAssertTrue(machine.apply(.captureInterrupted(.captureInterrupted("device"))).didTransition)
        XCTAssertEqual(machine.state, .failed(.captureInterrupted("device")))
    }

    func testHotkeyRegistrationFailureIsIgnoredWhileCapturing() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        machine.apply(.captureStarted)
        XCTAssertFalse(machine.apply(.hotkeyRegistrationFailed("collision")).didTransition)
        XCTAssertEqual(machine.state, .recording)
    }

    func testAuthorizationRevokedWhileRecordingBecomesRecoverableFailure() {
        var machine = RecordingStateMachine(state: .ready)
        machine.apply(.hotkeyPressed)
        machine.apply(.captureStarted)
        XCTAssertTrue(machine.apply(.authorizationResolved(.denied)).didTransition)
        XCTAssertEqual(machine.state, .failed(.captureInterrupted("Microphone access was revoked")))
    }

    func testUnrelatedEventsAreRejectedNotApplied() {
        var machine = RecordingStateMachine(state: .ready)
        XCTAssertFalse(machine.apply(.utteranceCompleted).didTransition)
        XCTAssertFalse(machine.apply(.captureStarted).didTransition)
        XCTAssertFalse(machine.apply(.maximumDurationReached).didTransition)
        XCTAssertEqual(machine.state, .ready)
    }
}
