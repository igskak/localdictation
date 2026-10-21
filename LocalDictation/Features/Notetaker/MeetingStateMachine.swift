import Foundation

enum MeetingPlatform: String, Sendable, Hashable, Codable {
    case zoom
    case googleMeet
    case manual
}

enum DetectionConfidence: Sendable, Hashable {
    case possible
    case probable
    case confirmed
}

struct MeetingCandidate: Sendable, Hashable {
    let platform: MeetingPlatform
    let processIdentifier: pid_t?
    let confidence: DetectionConfidence
}

struct MeetingSession: Sendable, Hashable {
    let id: UUID
}

enum MeetingFinalizationStage: Int, CaseIterable, Sendable, Hashable {
    case drainingAudio
    case finishingTranscript
    case assigningSpeakers
    case generatingSummary

    fileprivate var next: MeetingFinalizationStage? {
        Self(rawValue: rawValue + 1)
    }
}

/// Closed, content-free failure categories suitable for state and local logs.
enum MeetingRecoverableReason: CaseIterable, Sendable, Hashable {
    case permissionRevoked
    case audioDeviceChanged
    case systemSleep
    case applicationTerminated
    case transcriptionQueueFull
    case captureFailed
    case finalizationFailed
}

enum MeetingState: Sendable, Hashable {
    case disabled
    case idle
    case detected(MeetingCandidate)
    case awaitingConsent(MeetingCandidate?)
    case starting
    case recording(MeetingSession)
    case paused(MeetingSession)
    case stopping(MeetingSession)
    case finalizing(meetingID: UUID, stage: MeetingFinalizationStage)
    case completed(meetingID: UUID)
    case partial(meetingID: UUID?, reason: MeetingRecoverableReason)
    case failed(MeetingRecoverableReason)
}

enum MeetingEvent: Sendable, Hashable {
    case featureEnabled
    case featureDisabled
    case candidateDetected(MeetingCandidate)
    case candidateDismissed
    case recordingRequested
    case consentGranted
    case consentCancelled
    case recordingStarted(MeetingSession)
    case pauseRequested(meetingID: UUID)
    case resumeRequested(meetingID: UUID)
    case stopRequested(meetingID: UUID)
    case captureStopped(meetingID: UUID)
    case finalizationAdvanced(meetingID: UUID, stage: MeetingFinalizationStage)
    case finalizationCompleted(meetingID: UUID)
    case interrupted(meetingID: UUID?, reason: MeetingRecoverableReason, hasTranscript: Bool)
    case reset
}

/// Pure meeting lifecycle. It has no clock, AppKit, Core Audio, disk, or service
/// dependency; callers perform effects only after observing a transition.
struct MeetingStateMachine: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case transitioned(from: MeetingState, to: MeetingState)
        case unchanged(MeetingState)
        case rejected(MeetingState, MeetingEvent)
    }

    private(set) var state: MeetingState

    init(state: MeetingState = .disabled) {
        self.state = state
    }

    @discardableResult
    mutating func apply(_ event: MeetingEvent) -> Outcome {
        switch resolution(from: state, event: event) {
        case let .transition(next):
            let previous = state
            state = next
            return .transitioned(from: previous, to: next)
        case .unchanged:
            return .unchanged(state)
        case .rejected:
            return .rejected(state, event)
        }
    }

    private enum Resolution {
        case transition(MeetingState)
        case unchanged
        case rejected
    }

    private func resolution(from state: MeetingState, event: MeetingEvent) -> Resolution {
        switch (state, event) {
        case (.disabled, .featureEnabled):
            return .transition(.idle)
        case (.disabled, .featureDisabled):
            return .unchanged

        case (.idle, .featureDisabled),
             (.detected, .featureDisabled),
             (.awaitingConsent, .featureDisabled):
            return .transition(.disabled)

        case let (.idle, .candidateDetected(candidate)):
            return .transition(.detected(candidate))
        case let (.detected(current), .candidateDetected(candidate)):
            return current == candidate ? .unchanged : .transition(.detected(candidate))
        case (.detected, .candidateDismissed):
            return .transition(.idle)

        case (.idle, .recordingRequested):
            return .transition(.awaitingConsent(nil))
        case let (.detected(candidate), .recordingRequested):
            return .transition(.awaitingConsent(candidate))
        case (.awaitingConsent, .consentGranted):
            return .transition(.starting)
        case (.awaitingConsent, .consentCancelled):
            return .transition(.idle)

        case let (.starting, .recordingStarted(session)):
            return .transition(.recording(session))

        case let (.recording(session), .pauseRequested(meetingID)):
            return session.id == meetingID ? .transition(.paused(session)) : .rejected
        case let (.paused(session), .resumeRequested(meetingID)):
            return session.id == meetingID ? .transition(.recording(session)) : .rejected

        case let (.recording(session), .stopRequested(meetingID)),
             let (.paused(session), .stopRequested(meetingID)):
            return session.id == meetingID ? .transition(.stopping(session)) : .rejected
        case let (.stopping(session), .stopRequested(meetingID)):
            return session.id == meetingID ? .unchanged : .rejected
        case let (.finalizing(currentID, _), .stopRequested(meetingID)),
             let (.completed(currentID), .stopRequested(meetingID)):
            return currentID == meetingID ? .unchanged : .rejected
        case let (.partial(currentID?, _), .stopRequested(meetingID)):
            return currentID == meetingID ? .unchanged : .rejected

        case let (.stopping(session), .captureStopped(meetingID)):
            guard session.id == meetingID else { return .rejected }
            return .transition(.finalizing(meetingID: meetingID, stage: .drainingAudio))
        case let (.finalizing(currentID, .drainingAudio), .captureStopped(meetingID)):
            return currentID == meetingID ? .unchanged : .rejected

        case let (.finalizing(currentID, currentStage), .finalizationAdvanced(meetingID, nextStage)):
            guard currentID == meetingID else { return .rejected }
            if currentStage == nextStage { return .unchanged }
            guard currentStage.next == nextStage else { return .rejected }
            return .transition(.finalizing(meetingID: meetingID, stage: nextStage))

        case let (.finalizing(currentID, _), .finalizationCompleted(meetingID)):
            guard currentID == meetingID else { return .rejected }
            return .transition(.completed(meetingID: meetingID))
        case let (.completed(currentID), .finalizationCompleted(meetingID)):
            return currentID == meetingID ? .unchanged : .rejected

        case (.completed, .reset), (.partial, .reset), (.failed, .reset):
            return .transition(.idle)

        case let (.starting, .interrupted(meetingID, reason, hasTranscript)):
            guard meetingID == nil else { return .rejected }
            return .transition(interruptedState(meetingID: meetingID, reason: reason, hasTranscript: hasTranscript))
        case let (.recording(session), .interrupted(meetingID, reason, hasTranscript)),
             let (.paused(session), .interrupted(meetingID, reason, hasTranscript)),
             let (.stopping(session), .interrupted(meetingID, reason, hasTranscript)):
            guard meetingID == session.id else { return .rejected }
            return .transition(interruptedState(meetingID: meetingID, reason: reason, hasTranscript: hasTranscript))
        case let (.finalizing(currentID, _), .interrupted(meetingID, reason, hasTranscript)):
            guard meetingID == currentID else { return .rejected }
            return .transition(interruptedState(meetingID: meetingID, reason: reason, hasTranscript: hasTranscript))
        case let (.partial(currentID, currentReason), .interrupted(meetingID, reason, _)):
            return currentID == meetingID && currentReason == reason ? .unchanged : .rejected
        case let (.failed(currentReason), .interrupted(_, reason, hasTranscript)):
            return !hasTranscript && currentReason == reason ? .unchanged : .rejected

        default:
            return .rejected
        }
    }

    private func interruptedState(
        meetingID: UUID?,
        reason: MeetingRecoverableReason,
        hasTranscript: Bool
    ) -> MeetingState {
        if hasTranscript {
            return .partial(meetingID: meetingID, reason: reason)
        }
        return .failed(reason)
    }
}
