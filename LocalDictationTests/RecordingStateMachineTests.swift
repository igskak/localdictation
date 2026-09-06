import XCTest
@testable import Witness

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

    // MARK: - Phase 2 transcription transitions

    func testTranscriptionStartsAfterAnUtteranceCompletes() {
        var machine = RecordingStateMachine(state: .finishing)
        XCTAssertTrue(machine.apply(.utteranceCompleted).didTransition)
        XCTAssertEqual(machine.state, .ready)
        XCTAssertTrue(machine.apply(.transcriptionStarted).didTransition)
        XCTAssertEqual(machine.state, .transcribing)
        XCTAssertTrue(machine.apply(.transcriptionFinished).didTransition)
        XCTAssertEqual(machine.state, .ready)
    }

    func testTranscriptionFailureIsRecoverable() {
        var machine = RecordingStateMachine(state: .transcribing)
        XCTAssertTrue(machine.apply(.transcriptionFailed("engine died")).didTransition)
        XCTAssertEqual(machine.state, .failed(.transcription("engine died")))
        XCTAssertTrue(machine.apply(.recoveryRequested).didTransition)
        XCTAssertEqual(machine.state, .ready)
    }

    /// Pressing the hotkey during inference starts the next utterance rather
    /// than being swallowed; the coordinator supersedes the running request.
    func testNewRecordingSupersedesTranscription() {
        var machine = RecordingStateMachine(state: .transcribing)
        XCTAssertTrue(machine.apply(.hotkeyPressed).didTransition)
        XCTAssertEqual(machine.state, .starting)
    }

    func testTranscriptionCannotStartFromACapturingState() {
        for state in [RecordingState.starting, .recording, .finishing] {
            var machine = RecordingStateMachine(state: state)
            XCTAssertFalse(machine.apply(.transcriptionStarted).didTransition)
            XCTAssertEqual(machine.state, state)
        }
    }

    /// Transcription runs on audio that is already captured, so neither an
    /// authorization re-read nor a hotkey registration result may overwrite it.
    func testTranscribingStateSurvivesOSOriginatedEvents() {
        var machine = RecordingStateMachine(state: .transcribing)
        XCTAssertFalse(machine.apply(.authorizationResolved(.authorized)).didTransition)
        XCTAssertEqual(machine.state, .transcribing)
        XCTAssertFalse(machine.apply(.hotkeyRegistrationFailed("taken")).didTransition)
        XCTAssertEqual(machine.state, .transcribing)
    }

    func testTranscriptionEventsAreRejectedOutsideTheirStates() {
        var machine = RecordingStateMachine(state: .ready)
        XCTAssertFalse(machine.apply(.transcriptionFinished).didTransition)
        XCTAssertFalse(machine.apply(.transcriptionFailed("nope")).didTransition)
        XCTAssertEqual(machine.state, .ready)
    }

    // MARK: - Insertion

    /// The two places a finished result can leave the app from: a transcript
    /// that has just arrived, and the explicit action offered when automatic
    /// insertion is switched off. Phase 5 removed the third — a review no
    /// longer authorizes an insertion, because the insertion already happened.
    func testInsertionStartsFromEveryStateAResultCanBeFinishedIn() {
        for state in [RecordingState.transcribing, .ready] {
            var machine = RecordingStateMachine(state: state)
            XCTAssertTrue(machine.apply(.insertionStarted).didTransition, "\(state) must be able to insert")
            XCTAssertEqual(machine.state, .inserting)
            XCTAssertTrue(machine.apply(.insertionFinished).didTransition)
            XCTAssertEqual(machine.state, .ready)
        }
    }

    func testInsertionCannotStartWhileCapturing() {
        for state in [RecordingState.starting, .recording, .finishing] {
            var machine = RecordingStateMachine(state: state)
            XCTAssertFalse(machine.apply(.insertionStarted).didTransition)
            XCTAssertEqual(machine.state, state)
        }
    }

    /// The paste path waits for the target application to read the pasteboard,
    /// and the next dictation may arrive inside that window.
    func testNewRecordingSupersedesAnInsertionStillSettling() {
        var machine = RecordingStateMachine(state: .inserting)
        XCTAssertTrue(machine.apply(.hotkeyPressed).didTransition)
        XCTAssertEqual(machine.state, .starting)
    }

    func testInsertingStateSurvivesOSOriginatedEvents() {
        var machine = RecordingStateMachine(state: .inserting)
        XCTAssertFalse(machine.apply(.authorizationResolved(.authorized)).didTransition)
        XCTAssertEqual(machine.state, .inserting)
        XCTAssertFalse(machine.apply(.hotkeyRegistrationFailed("taken")).didTransition)
        XCTAssertEqual(machine.state, .inserting)
    }

    func testInsertionEventsAreRejectedOutsideTheirStates() {
        var machine = RecordingStateMachine(state: .ready)
        XCTAssertFalse(machine.apply(.insertionFinished).didTransition)
        XCTAssertEqual(machine.state, .ready)

        machine = RecordingStateMachine(state: .recording)
        XCTAssertFalse(machine.apply(.insertionFinished).didTransition)
        XCTAssertEqual(machine.state, .recording)
    }

    func testInsertingCountsAsBusy() {
        XCTAssertTrue(RecordingState.inserting.isBusy)
        XCTAssertTrue(RecordingState.inserting.isInserting)
        XCTAssertFalse(RecordingState.inserting.isCapturing)
    }

    /// The other half of the superseding rule, and the half that had no test.
    ///
    /// Unlocked, a press during inference or insertion starts the next
    /// utterance. Locked, the same press is refused: text already spoken has
    /// been paid for and has to reach the user, so the words in flight finish
    /// on their own terms and the price waits for the next press.
    ///
    /// It is written down because the silence is load-bearing and invisible.
    /// `DictationCoordinator.beginCapture` only counts a paywall request when
    /// this event is accepted, so a press landing inside the busy window opens
    /// no window at all — which is what a test in `PaywallWindowTests` spent
    /// fifteen seconds waiting for, roughly one full run in five, until
    /// `lock(_:)` there learned to wait for `.locked` rather than for the
    /// entitlement alone.
    func testALockedPressIsRefusedWhileSomethingIsStillInFlight() {
        for state in [RecordingState.starting, .recording, .finishing, .transcribing, .inserting] {
            var machine = RecordingStateMachine(state: state, lock: .activationRequired)
            XCTAssertFalse(machine.apply(.hotkeyPressed).didTransition, "\(state) is busy")
            XCTAssertEqual(machine.state, state, "\(state) must be left alone")
        }

        // And once nothing is in flight, the same press is answered.
        var settled = RecordingStateMachine(state: .ready, lock: .activationRequired)
        XCTAssertTrue(settled.apply(.hotkeyPressed).didTransition)
        XCTAssertEqual(settled.state, .locked(.activationRequired))
    }
}
