import XCTest
@testable import Witness

final class MeetingStateMachineTests: XCTestCase {
    private let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private var candidate: MeetingCandidate {
        MeetingCandidate(platform: .zoom, processIdentifier: 42, confidence: .confirmed)
    }

    private var otherCandidate: MeetingCandidate {
        MeetingCandidate(platform: .googleMeet, processIdentifier: 84, confidence: .probable)
    }

    private var session: MeetingSession { MeetingSession(id: meetingID) }

    func testEveryStateAndEventCaseHasAnExplicitExpectedOutcome() {
        let states: [MeetingState] = [
            .disabled,
            .idle,
            .detected(candidate),
            .awaitingConsent(candidate),
            .starting,
            .recording(session),
            .paused(session),
            .stopping(session),
            .finalizing(meetingID: meetingID, stage: .drainingAudio),
            .finalizing(meetingID: meetingID, stage: .finishingTranscript),
            .finalizing(meetingID: meetingID, stage: .assigningSpeakers),
            .finalizing(meetingID: meetingID, stage: .generatingSummary),
            .completed(meetingID: meetingID),
            .partial(meetingID: meetingID, reason: .transcriptionQueueFull),
            .failed(.permissionRevoked),
        ]
        let events: [MeetingEvent] = [
            .featureEnabled,
            .featureDisabled,
            .candidateDetected(candidate),
            .candidateDetected(otherCandidate),
            .candidateDismissed,
            .recordingRequested,
            .consentGranted,
            .consentCancelled,
            .recordingStarted(session),
            .pauseRequested(meetingID: meetingID),
            .pauseRequested(meetingID: staleID),
            .resumeRequested(meetingID: meetingID),
            .resumeRequested(meetingID: staleID),
            .stopRequested(meetingID: meetingID),
            .stopRequested(meetingID: staleID),
            .captureStopped(meetingID: meetingID),
            .captureStopped(meetingID: staleID),
            .finalizationAdvanced(meetingID: meetingID, stage: .drainingAudio),
            .finalizationAdvanced(meetingID: meetingID, stage: .finishingTranscript),
            .finalizationAdvanced(meetingID: meetingID, stage: .assigningSpeakers),
            .finalizationAdvanced(meetingID: meetingID, stage: .generatingSummary),
            .finalizationAdvanced(meetingID: staleID, stage: .finishingTranscript),
            .finalizationCompleted(meetingID: meetingID),
            .finalizationCompleted(meetingID: staleID),
            .interrupted(meetingID: nil, reason: .permissionRevoked, hasTranscript: false),
            .interrupted(meetingID: meetingID, reason: .transcriptionQueueFull, hasTranscript: true),
            .interrupted(meetingID: meetingID, reason: .permissionRevoked, hasTranscript: false),
            .interrupted(meetingID: staleID, reason: .captureFailed, hasTranscript: true),
            .reset,
        ]

        for state in states {
            for event in events {
                var machine = MeetingStateMachine(state: state)
                let actual = machine.apply(event)
                let expected = expectedOutcome(from: state, event: event)
                XCTAssertEqual(actual, expected, "Unexpected outcome for \(state) + \(event)")
                XCTAssertEqual(machine.state, resultingState(for: expected), "Unexpected state for \(state) + \(event)")
            }
        }
    }

    func testEveryRecoverableOperationalInterruptionIsIdempotent() {
        let activeStates: [MeetingState] = [
            .recording(session),
            .paused(session),
            .stopping(session),
            .finalizing(meetingID: meetingID, stage: .finishingTranscript),
        ]

        for reason in MeetingRecoverableReason.allCases {
            for state in activeStates {
                for hasTranscript in [false, true] {
                    let event = MeetingEvent.interrupted(
                        meetingID: meetingID,
                        reason: reason,
                        hasTranscript: hasTranscript
                    )
                    var machine = MeetingStateMachine(state: state)
                    let first = machine.apply(event)
                    let settled = machine.state
                    let second = machine.apply(event)

                    XCTAssertNotEqual(first, .rejected(state, event))
                    XCTAssertEqual(second, .unchanged(settled))
                    XCTAssertEqual(machine.state, settled)
                }
            }
        }
    }

    func testStaleSessionEventsCannotAffectTheCurrentMeeting() {
        let events: [MeetingEvent] = [
            .pauseRequested(meetingID: staleID),
            .resumeRequested(meetingID: staleID),
            .stopRequested(meetingID: staleID),
            .captureStopped(meetingID: staleID),
            .finalizationAdvanced(meetingID: staleID, stage: .finishingTranscript),
            .finalizationCompleted(meetingID: staleID),
            .interrupted(meetingID: staleID, reason: .captureFailed, hasTranscript: true),
        ]
        let states: [MeetingState] = [
            .recording(session),
            .paused(session),
            .stopping(session),
            .finalizing(meetingID: meetingID, stage: .drainingAudio),
        ]

        for state in states {
            for event in events {
                var machine = MeetingStateMachine(state: state)
                if case .rejected = machine.apply(event) {
                    XCTAssertEqual(machine.state, state)
                } else {
                    XCTFail("Stale event \(event) changed \(state)")
                }
            }
        }
    }

    func testFailureKeepsUsefulTranscriptAsPartial() {
        var machine = MeetingStateMachine(state: .recording(session))
        machine.apply(.interrupted(
            meetingID: meetingID,
            reason: .audioDeviceChanged,
            hasTranscript: true
        ))

        XCTAssertEqual(machine.state, .partial(meetingID: meetingID, reason: .audioDeviceChanged))
    }

    private func resultingState(for outcome: MeetingStateMachine.Outcome) -> MeetingState {
        switch outcome {
        case let .transitioned(_, to): to
        case let .unchanged(state): state
        case let .rejected(state, _): state
        }
    }

    private func expectedOutcome(from state: MeetingState, event: MeetingEvent) -> MeetingStateMachine.Outcome {
        func transition(_ next: MeetingState) -> MeetingStateMachine.Outcome {
            .transitioned(from: state, to: next)
        }

        func unchanged() -> MeetingStateMachine.Outcome { .unchanged(state) }
        func rejected() -> MeetingStateMachine.Outcome { .rejected(state, event) }

        switch (state, event) {
        case (.disabled, .featureEnabled): return transition(.idle)
        case (.disabled, .featureDisabled): return unchanged()
        case (.idle, .featureDisabled), (.detected, .featureDisabled), (.awaitingConsent, .featureDisabled):
            return transition(.disabled)
        case let (.idle, .candidateDetected(value)): return transition(.detected(value))
        case let (.detected(current), .candidateDetected(value)):
            return current == value ? unchanged() : transition(.detected(value))
        case (.detected, .candidateDismissed): return transition(.idle)
        case (.idle, .recordingRequested): return transition(.awaitingConsent(nil))
        case let (.detected(value), .recordingRequested): return transition(.awaitingConsent(value))
        case (.awaitingConsent, .consentGranted): return transition(.starting)
        case (.awaitingConsent, .consentCancelled): return transition(.idle)
        case let (.starting, .recordingStarted(value)): return transition(.recording(value))
        case let (.recording(value), .pauseRequested(id)) where value.id == id:
            return transition(.paused(value))
        case let (.paused(value), .resumeRequested(id)) where value.id == id:
            return transition(.recording(value))
        case let (.recording(value), .stopRequested(id)) where value.id == id:
            return transition(.stopping(value))
        case let (.paused(value), .stopRequested(id)) where value.id == id:
            return transition(.stopping(value))
        case let (.stopping(value), .stopRequested(id)) where value.id == id:
            return unchanged()
        case let (.finalizing(id, _), .stopRequested(eventID)) where id == eventID,
             let (.completed(id), .stopRequested(eventID)) where id == eventID,
             let (.partial(id?, _), .stopRequested(eventID)) where id == eventID:
            return unchanged()
        case let (.stopping(value), .captureStopped(id)) where value.id == id:
            return transition(.finalizing(meetingID: id, stage: .drainingAudio))
        case let (.finalizing(id, .drainingAudio), .captureStopped(eventID)) where id == eventID:
            return unchanged()
        case let (.finalizing(id, stage), .finalizationAdvanced(eventID, next)) where id == eventID:
            if stage == next { return unchanged() }
            if next.rawValue == stage.rawValue + 1 {
                return transition(.finalizing(meetingID: id, stage: next))
            }
            return rejected()
        case let (.finalizing(id, _), .finalizationCompleted(eventID)) where id == eventID:
            return transition(.completed(meetingID: id))
        case let (.completed(id), .finalizationCompleted(eventID)) where id == eventID:
            return unchanged()
        case (.completed, .reset), (.partial, .reset), (.failed, .reset):
            return transition(.idle)
        case let (.starting, .interrupted(nil, reason, hasTranscript)):
            return transition(hasTranscript ? .partial(meetingID: nil, reason: reason) : .failed(reason))
        case let (.recording(value), .interrupted(id?, reason, hasTranscript)) where value.id == id:
            return transition(hasTranscript ? .partial(meetingID: id, reason: reason) : .failed(reason))
        case let (.paused(value), .interrupted(id?, reason, hasTranscript)) where value.id == id:
            return transition(hasTranscript ? .partial(meetingID: id, reason: reason) : .failed(reason))
        case let (.stopping(value), .interrupted(id?, reason, hasTranscript)) where value.id == id:
            return transition(hasTranscript ? .partial(meetingID: id, reason: reason) : .failed(reason))
        case let (.finalizing(id, _), .interrupted(eventID?, reason, hasTranscript)) where id == eventID:
            return transition(hasTranscript ? .partial(meetingID: id, reason: reason) : .failed(reason))
        case let (.partial(id, reason), .interrupted(eventID, eventReason, _))
            where id == eventID && reason == eventReason:
            return unchanged()
        case let (.failed(reason), .interrupted(_, eventReason, false)) where reason == eventReason:
            return unchanged()
        default:
            return rejected()
        }
    }
}
