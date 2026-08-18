import Foundation

/// Microphone authorization as the application models it, decoupled from
/// `AVAuthorizationStatus` so the coordinator can be tested without AVFoundation.
enum MicrophoneAuthorization: String, Sendable, Equatable, CaseIterable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var allowsCapture: Bool { self == .authorized }

    /// `true` when a user action can still produce a system permission dialog.
    var isRequestable: Bool { self == .notDetermined }
}
