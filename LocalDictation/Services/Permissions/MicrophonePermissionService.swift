import Foundation

/// Microphone authorization boundary.
///
/// Reading the current status must never present a dialog; only
/// `requestAccess()` may, and only after a deliberate user action.
protocol MicrophonePermissionService: AnyObject, Sendable {
    var currentAuthorization: MicrophoneAuthorization { get }
    func requestAccess() async -> MicrophoneAuthorization
    @MainActor func openSystemSettings()
}
