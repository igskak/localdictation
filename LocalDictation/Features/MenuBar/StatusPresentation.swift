import Foundation

enum StatusTint: String, Sendable, Equatable {
    case neutral
    case ready
    case active
    case warning
}

/// Pure mapping from recording state to user-facing copy, so the wording can be
/// unit-tested without instantiating SwiftUI views.
struct StatusPresentation: Sendable, Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let tint: StatusTint
    /// Actions the menu should offer for this state.
    let showsPermissionRequest: Bool
    let showsSystemSettingsShortcut: Bool
    let showsRecoveryAction: Bool
    /// Whether the menu should offer the way out of a licensing lock. Given a
    /// default so the fifteen states that have nothing to do with licensing do
    /// not each have to say so.
    private(set) var showsLicenseAction = false

    /// `modelState` only changes the transcribing copy, so callers that do not
    /// have an engine can leave it alone.
    ///
    /// `attentionIsPending` is the indicator, and it is deliberately allowed to
    /// change only the idle state. A triangle is worth showing while nothing
    /// else is happening; painted over "Recording" or "Transcribing" it would
    /// be describing the previous utterance while the user is producing the
    /// next one, which is the one thing an indicator must never do.
    init(
        state: RecordingState,
        binding: HotkeyBinding,
        modelState: TranscriptionModelState = .ready,
        attentionIsPending: Bool = false
    ) {
        if state == .ready, attentionIsPending {
            title = "Worth a look"
            detail = "Some fragments in the last result are worth checking. The text is already in place."
            systemImage = "exclamationmark.triangle"
            tint = .warning
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false
            return
        }

        switch state {
        case .launching:
            title = "Starting up"
            detail = "Checking microphone access."
            systemImage = "mic.circle"
            tint = .neutral
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .needsPermission:
            title = "Microphone access required"
            detail = "Grant access to enable push-to-talk dictation."
            systemImage = "mic.circle"
            tint = .warning
            showsPermissionRequest = true
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .requestingPermission:
            title = "Waiting for your answer"
            detail = "Approve the macOS microphone prompt."
            systemImage = "mic.circle"
            tint = .neutral
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case let .permissionDenied(restricted):
            title = restricted ? "Microphone access restricted" : "Microphone access denied"
            detail = restricted
                ? "A device policy blocks microphone access. Contact whoever manages this Mac."
                : "Enable LocalDictation under Privacy & Security → Microphone, then return here."
            systemImage = "exclamationmark.triangle"
            tint = .warning
            showsPermissionRequest = false
            showsSystemSettingsShortcut = true
            showsRecoveryAction = false

        case .ready:
            title = "Ready"
            detail = "Hold \(binding.displayString) to record."
            systemImage = "waveform.circle"
            tint = .ready
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .starting:
            title = "Starting capture"
            detail = "Opening the microphone."
            systemImage = "waveform.circle"
            tint = .active
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .recording:
            title = "Recording"
            detail = "Release \(binding.displayString) to finish."
            systemImage = "waveform.circle.fill"
            tint = .active
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .finishing:
            title = "Finishing utterance"
            detail = "Closing the capture buffer."
            systemImage = "waveform.circle"
            tint = .active
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .transcribing:
            // Recording during a load is allowed on purpose — the audio is
            // already captured and throwing it away would be worse. But saying
            // "Transcribing" while the engine is still loading reads as a hang,
            // so the wait is named for what it is.
            title = modelState.isPreparing ? "Waiting for the speech model" : "Transcribing"
            detail = modelState.isPreparing
                ? "Your recording is held in memory. Transcription starts the moment the model finishes loading."
                : "Recognizing speech on this Mac. Hold \(binding.displayString) to start the next one."
            systemImage = "waveform.badge.magnifyingglass"
            tint = .active
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case .inserting:
            title = "Inserting"
            detail = "Putting the text where you were typing."
            systemImage = "text.cursor"
            tint = .active
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

        case let .locked(lock):
            // The one state where the app is working perfectly and still will
            // not do the thing. It says which of the two doors is in front of
            // the user — an address, or a purchase — and never both.
            switch lock {
            case .activationRequired:
                title = "Activate to keep going"
                detail = "The first dictations are ungated. Add your email under Settings → License and the trial runs for fourteen days."
            case let .expired(.trial, at):
                title = "Trial finished"
                detail = "The trial ended \(Self.dayFormatter.string(from: at)). A license brings it back, on this Mac and one more."
            case let .expired(kind, at):
                title = "\(kind.displayName) license expired"
                detail = "It ran out \(Self.dayFormatter.string(from: at)). Renewing unlocks dictation again; nothing on this Mac was touched."
            }
            systemImage = "lock.circle"
            tint = .warning
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false
            showsLicenseAction = true

        case let .failed(failure):
            title = "Needs attention"
            detail = failure.message
            systemImage = "exclamationmark.triangle"
            tint = .warning
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = true
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
