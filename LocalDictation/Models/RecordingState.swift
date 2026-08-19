import Foundation

/// Reasons a capture attempt failed. Every case is recoverable: the coordinator
/// can return to `.ready` once the underlying condition is resolved.
enum RecordingFailure: Sendable, Equatable {
    case hotkeyRegistration(String)
    case captureStart(String)
    case captureInterrupted(String)
    case transcription(String)

    var message: String {
        switch self {
        case let .hotkeyRegistration(detail):
            "Hotkey unavailable: \(detail)"
        case let .captureStart(detail):
            "Recording could not start: \(detail)"
        case let .captureInterrupted(detail):
            "Recording stopped: \(detail)"
        case let .transcription(detail):
            detail
        }
    }
}

/// Explicit lifecycle of the dictation slice. Capture ends at `.finishing`;
/// Phase 2 attaches transcription after the utterance is handed over, so the
/// capture path is unchanged and a new recording can start while inference runs.
///
/// Phase 3 adds `.reviewing`, which the app enters only when the risk policy
/// says the interruption is earned. The state is what bounds the recording's
/// lifetime: audio is held while it lasts and released the moment it ends — or
/// immediately, when the decision was that no review is needed.
///
/// Phase 4 adds `.inserting`, which is short but not instantaneous: the paste
/// path posts a key event and then waits for the target application to read the
/// pasteboard. A state makes that window explicit, so a hotkey press arriving
/// inside it supersedes the insertion instead of racing it.
enum RecordingState: Sendable, Equatable {
    case launching
    case needsPermission
    case requestingPermission
    case permissionDenied(restricted: Bool)
    case ready
    case starting
    case recording
    case finishing
    case transcribing
    case reviewing
    case inserting
    case failed(RecordingFailure)

    var isCapturing: Bool {
        switch self {
        case .starting, .recording, .finishing:
            true
        default:
            false
        }
    }

    var isTranscribing: Bool { self == .transcribing }

    var isReviewing: Bool { self == .reviewing }

    var isInserting: Bool { self == .inserting }

    /// States whose progress must not be clobbered by an authorization re-read
    /// or a hotkey registration result arriving from the OS.
    var isBusy: Bool { isCapturing || isTranscribing || isReviewing || isInserting }
}

/// Events the coordinator feeds into the state machine. Anything not listed as a
/// legal transition for the current state is rejected instead of silently applied.
enum RecordingEvent: Sendable, Equatable {
    case authorizationResolved(MicrophoneAuthorization)
    case permissionRequestStarted
    case hotkeyPressed
    case hotkeyReleased
    case captureStarted
    case captureFailed(RecordingFailure)
    case captureInterrupted(RecordingFailure)
    case maximumDurationReached
    case utteranceCompleted
    case transcriptionStarted
    case transcriptionFinished
    case transcriptionFailed(String)
    case reviewRequired
    case reviewCompleted
    case insertionStarted
    case insertionFinished
    case hotkeyRegistrationFailed(String)
    case recoveryRequested
}

/// Deterministic, pure state machine. It performs no side effects; the
/// coordinator observes the returned outcome and drives the services.
struct RecordingStateMachine: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case transitioned(from: RecordingState, to: RecordingState)
        case rejected(RecordingState, RecordingEvent)

        var didTransition: Bool {
            if case .transitioned = self { return true }
            return false
        }
    }

    private(set) var state: RecordingState

    init(state: RecordingState = .launching) {
        self.state = state
    }

    static func state(for authorization: MicrophoneAuthorization) -> RecordingState {
        switch authorization {
        case .authorized:
            .ready
        case .notDetermined:
            .needsPermission
        case .denied:
            .permissionDenied(restricted: false)
        case .restricted:
            .permissionDenied(restricted: true)
        }
    }

    @discardableResult
    mutating func apply(_ event: RecordingEvent) -> Outcome {
        guard let next = Self.nextState(from: state, event: event) else {
            return .rejected(state, event)
        }
        let previous = state
        state = next
        return .transitioned(from: previous, to: next)
    }

    private static func nextState(from state: RecordingState, event: RecordingEvent) -> RecordingState? {
        // Authorization results and hotkey registration failures are accepted in
        // every non-capturing state: the OS can change them behind our back.
        switch event {
        case let .authorizationResolved(authorization):
            guard !state.isCapturing else {
                return authorization.allowsCapture ? nil : .failed(.captureInterrupted("Microphone access was revoked"))
            }
            // Transcription runs on audio that is already captured, a review
            // is the user reading a result, and an insertion is text already on
            // its way out, so an authorization change must not interrupt or
            // overwrite any of them.
            guard !state.isTranscribing, !state.isReviewing, !state.isInserting else { return nil }
            return Self.state(for: authorization)

        case let .hotkeyRegistrationFailed(detail):
            guard !state.isBusy else { return nil }
            return .failed(.hotkeyRegistration(detail))

        default:
            break
        }

        switch (state, event) {
        case (.needsPermission, .permissionRequestStarted):
            return .requestingPermission

        case (.ready, .hotkeyPressed):
            return .starting

        case (.starting, .captureStarted):
            return .recording
        case (.starting, .hotkeyReleased):
            // Released before the engine finished starting: finish as soon as the
            // capture session reports it is running.
            return .finishing
        case let (.starting, .captureFailed(failure)):
            return .failed(failure)
        case let (.starting, .captureInterrupted(failure)):
            return .failed(failure)

        case (.recording, .hotkeyReleased):
            return .finishing
        case (.recording, .maximumDurationReached):
            return .finishing
        case let (.recording, .captureInterrupted(failure)):
            return .failed(failure)

        case (.finishing, .captureStarted):
            // Start completed after the key was already released; stay in
            // `.finishing` so the coordinator can stop immediately.
            return nil
        case (.finishing, .utteranceCompleted):
            return .ready
        case let (.finishing, .captureInterrupted(failure)):
            return .failed(failure)
        case let (.finishing, .captureFailed(failure)):
            return .failed(failure)

        case (.ready, .transcriptionStarted):
            return .transcribing
        case (.transcribing, .transcriptionFinished):
            return .ready
        case (.transcribing, .reviewRequired):
            return .reviewing
        case let (.transcribing, .transcriptionFailed(detail)):
            return .failed(.transcription(detail))
        case (.transcribing, .hotkeyPressed):
            // A new utterance supersedes the one being transcribed. The
            // coordinator cancels the in-flight request so it cannot deliver
            // a stale transcript into the new recording.
            return .starting

        case (.reviewing, .reviewCompleted):
            return .ready
        case (.reviewing, .hotkeyPressed):
            // Starting the next dictation ends the review. The coordinator
            // releases the retained audio on the way out, so the recording
            // never outlives the interaction it belonged to.
            return .starting
        case (.reviewing, .transcriptionStarted):
            // A review must finish before the next transcript can replace it.
            return nil

        // Insertion is entered from all three places text can be finished with:
        // a result that needed no review, a review the user accepted, and the
        // explicit action offered when automatic insertion is switched off.
        case (.transcribing, .insertionStarted):
            return .inserting
        case (.reviewing, .insertionStarted):
            return .inserting
        case (.ready, .insertionStarted):
            return .inserting

        case (.inserting, .insertionFinished):
            return .ready
        case (.inserting, .hotkeyPressed):
            // The next dictation supersedes an insertion still settling. The
            // coordinator drops the outcome of the superseded one, so a late
            // result cannot report on a recording that has been replaced.
            return .starting
        case (.inserting, .transcriptionStarted):
            // The utterance behind this insertion is finished; a transcript
            // arriving now belongs to a recording that has not superseded it.
            return nil

        case (.failed, .recoveryRequested):
            return .ready

        default:
            return nil
        }
    }
}
