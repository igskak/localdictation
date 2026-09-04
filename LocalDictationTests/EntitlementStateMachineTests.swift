import XCTest
@testable import Witness

/// The licensing precondition inside the dictation state machine, tested where
/// the machine is: as a pure value with no services attached.
final class EntitlementStateMachineTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_700_000_000)

    func testALockMovesAnIdleMacToLocked() {
        var machine = RecordingStateMachine(state: .ready)

        machine.apply(.entitlementResolved(.activationRequired, .authorized))

        XCTAssertEqual(machine.state, .locked(.activationRequired))
    }

    /// The rule that matters most. A trial running out while someone is
    /// speaking must not take the sentence with it.
    func testALockArrivingMidUtteranceDoesNotInterruptIt() {
        var machine = RecordingStateMachine(state: .recording)

        machine.apply(.entitlementResolved(.expired(.trial, at: expiry), .authorized))

        XCTAssertEqual(machine.state, .recording)
        machine.apply(.hotkeyReleased)
        XCTAssertEqual(machine.state, .finishing)
        machine.apply(.utteranceCompleted)
        XCTAssertEqual(machine.state, .locked(.expired(.trial, at: expiry)), "and it lands the moment the utterance is done")
    }

    func testATranscriptionThatOutlivesTheTrialStillFinishes() {
        var machine = RecordingStateMachine(state: .transcribing)

        machine.apply(.entitlementResolved(.activationRequired, .authorized))
        XCTAssertEqual(machine.state, .transcribing)

        machine.apply(.insertionStarted)
        XCTAssertEqual(machine.state, .inserting, "the text still goes where it was going")
        machine.apply(.insertionFinished)
        XCTAssertEqual(machine.state, .locked(.activationRequired))
    }

    func testALockedMacRefusesTheHotkey() {
        var machine = RecordingStateMachine(state: .locked(.activationRequired), lock: .activationRequired)

        machine.apply(.hotkeyPressed)

        XCTAssertEqual(machine.state, .locked(.activationRequired))
    }

    /// The authorization re-read runs on every activation of the app. If it
    /// could leave `.locked`, clicking the menu bar would unlock the product.
    func testRereadingMicrophoneAccessCannotUnlockTheApp() {
        var machine = RecordingStateMachine(state: .locked(.activationRequired), lock: .activationRequired)

        machine.apply(.authorizationResolved(.authorized))

        XCTAssertEqual(machine.state, .locked(.activationRequired))
    }

    func testUnlockingLandsOnTheStateTheMacIsActuallyIn() {
        var machine = RecordingStateMachine(state: .locked(.activationRequired), lock: .activationRequired)

        machine.apply(.entitlementResolved(nil, .denied))

        XCTAssertEqual(machine.state, .permissionDenied(restricted: false), "an activated Mac with no microphone is not ready")
    }

    func testUnlockingAnAuthorizedMacReturnsItToReady() {
        var machine = RecordingStateMachine(state: .locked(.expired(.trial, at: expiry)), lock: .expired(.trial, at: expiry))

        machine.apply(.entitlementResolved(nil, .authorized))

        XCTAssertEqual(machine.state, .ready)
    }

    /// A licensing refresh must not paper over a capture failure the user has
    /// not seen yet.
    func testALicensingRefreshDoesNotClearAFailure() {
        var machine = RecordingStateMachine(state: .failed(.captureStart("no input device")))

        machine.apply(.entitlementResolved(nil, .authorized))

        XCTAssertEqual(machine.state, .failed(.captureStart("no input device")))
    }
}
