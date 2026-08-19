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

    init(state: RecordingState, binding: HotkeyBinding) {
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
            title = "Transcribing"
            detail = "Recognizing speech on this Mac. Hold \(binding.displayString) to start the next one."
            systemImage = "waveform.badge.magnifyingglass"
            tint = .active
            showsPermissionRequest = false
            showsSystemSettingsShortcut = false
            showsRecoveryAction = false

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
}
