import Foundation

/// Accessibility authorization boundary.
///
/// The same shape as `MicrophonePermissionService`, and the same rule: reading
/// the current status must never present a dialog. Only `requestTrust()` may,
/// and only after the user has done something that needs it.
///
/// Unlike the microphone, this permission is never required at launch. Every
/// part of the app that worked before Phase 4 keeps working untrusted — only
/// insertion is unavailable, and its absence is a clipboard fallback rather
/// than a blocked feature.
protocol AccessibilityPermissionService: AnyObject, Sendable {
    var currentAuthorization: AccessibilityAuthorization { get }
    /// Shows the system prompt that offers to open Accessibility settings.
    /// Returns the authorization as it stands immediately afterwards, which is
    /// almost always still `.notTrusted`: macOS grants trust out of band, and
    /// the app finds out by re-reading later.
    func requestTrust() -> AccessibilityAuthorization
    @MainActor func openSystemSettings()
}
