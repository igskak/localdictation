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
/// Phase 3 added `.reviewing`, and Phase 5 removes it. Reading a report about
/// text that is already in the document is not a phase of dictation — it is
/// something the user may do, at their own pace, or never. Modelling it as a
/// state meant every review blocked the pipeline it was reporting on. The
/// recording's lifetime moved with it: audio is now held until the next
/// utterance begins or the user closes the review, and released the instant the
/// result turns out to be worth nothing.
///
/// Phase 6 adds `.locked`, which is not a failure and not a permission problem:
/// the app works, the Mac is simply not entitled to dictate until the trial is
/// activated or a license is entered. It is modelled here for the same reason
/// `.needsPermission` is — this machine is what decides whether a hotkey press
/// opens a microphone, and a precondition it cannot see is a precondition that
/// gets forgotten in one of the paths.
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
    case inserting
    case locked(EntitlementLock)
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

    var isInserting: Bool { self == .inserting }

    /// States whose progress must not be clobbered by an authorization re-read
    /// or a hotkey registration result arriving from the OS.
    var isBusy: Bool { isCapturing || isTranscribing || isInserting }
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
    case insertionStarted
    case insertionFinished
    /// The licensing state was re-read. Carries the microphone authorization
    /// alongside it because unlocking has to land on the right idle state, and
    /// this machine does not remember one.
    case entitlementResolved(EntitlementLock?, MicrophoneAuthorization)
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
    /// The licensing precondition, held beside the state rather than inside it.
    ///
    /// A lock that arrives while an utterance is in flight must not become the
    /// state — text already spoken has been paid for and has to reach the user
    /// — but it must still be remembered, or the next press would open the
    /// microphone anyway. Keeping it here is what lets both be true.
    private(set) var lock: EntitlementLock?

    init(state: RecordingState = .launching, lock: EntitlementLock? = nil) {
        self.state = state
        self.lock = lock
    }

    /// Where the machine comes to rest when work finishes: `.ready`, unless the
    /// Mac stopped being entitled while that work was running.
    private var restingState: RecordingState {
        if let lock { return .locked(lock) }
        return .ready
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
        // The precondition is recorded before the transition is computed, so a
        // lock arriving mid-utterance is already in force for the event after
        // it even when it changes no state now.
        if case let .entitlementResolved(lock, _) = event { self.lock = lock }

        guard let next = nextState(from: state, event: event) else {
            return .rejected(state, event)
        }
        let previous = state
        state = next
        return .transitioned(from: previous, to: next)
    }

    private func nextState(from state: RecordingState, event: RecordingEvent) -> RecordingState? {
        // Authorization results and hotkey registration failures are accepted in
        // every non-capturing state: the OS can change them behind our back.
        switch event {
        case let .entitlementResolved(lock, authorization):
            // Never mid-utterance. `apply` has already stored the lock, so the
            // next press is refused; what must not happen is the text of the
            // utterance in flight being dropped because a trial ran out while
            // the user was speaking it.
            guard !state.isBusy else { return nil }
            if let lock { return .locked(lock) }
            if case .failed = state { return nil }
            return Self.state(for: authorization)

        case let .authorizationResolved(authorization):
            // A locked Mac stays locked whatever the microphone says. This is
            // the one re-read that fires on every activation of the app, so
            // letting it out of `.locked` would unlock the app by accident.
            guard lock == nil else { return nil }
            guard !state.isCapturing else {
                return authorization.allowsCapture ? nil : .failed(.captureInterrupted("Microphone access was revoked"))
            }
            // Transcription runs on audio that is already captured and an
            // insertion is text already on its way out, so an authorization
            // change must not interrupt or overwrite either of them.
            guard !state.isTranscribing, !state.isInserting else { return nil }
            return Self.state(for: authorization)

        case let .hotkeyRegistrationFailed(detail):
            guard !state.isBusy else { return nil }
            guard lock == nil else { return nil }
            return .failed(.hotkeyRegistration(detail))

        case .hotkeyPressed where lock != nil:
            // Pressing the key is how most users will discover the lock, so it
            // answers rather than doing nothing — except while something is
            // still in flight, which must finish on its own terms.
            guard !state.isBusy else { return nil }
            return lock.map(RecordingState.locked)

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
            return restingState
        case let (.finishing, .captureInterrupted(failure)):
            return .failed(failure)
        case let (.finishing, .captureFailed(failure)):
            return .failed(failure)

        case (.ready, .transcriptionStarted):
            return .transcribing
        case (.transcribing, .transcriptionFinished):
            return restingState
        case let (.transcribing, .transcriptionFailed(detail)):
            return .failed(.transcription(detail))
        case (.transcribing, .hotkeyPressed):
            // A new utterance supersedes the one being transcribed. The
            // coordinator cancels the in-flight request so it cannot deliver
            // a stale transcript into the new recording.
            return .starting

        // Insertion is entered from the two places text is finished with: a
        // transcript that just arrived, and the explicit action offered when
        // automatic insertion is switched off.
        case (.transcribing, .insertionStarted):
            return .inserting
        case (.ready, .insertionStarted):
            return .inserting

        case (.inserting, .insertionFinished):
            return restingState
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
            return restingState

        default:
            return nil
        }
    }
}
