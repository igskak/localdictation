import AppKit
import ApplicationServices

/// Accessibility trust backed by `AXIsProcessTrusted`.
///
/// Reading the status never prompts, so constructing this service — and
/// consulting it on every state refresh — cannot produce a dialog.
///
/// There is no notification when trust changes. macOS grants it in System
/// Settings, out of band, and the app finds out by re-reading. The coordinator
/// therefore re-reads whenever the app becomes active, which is exactly the
/// moment the user comes back from granting it.
///
/// A development build loses its trust on every rebuild, because the entry is
/// keyed by code signature and an ad-hoc signature changes each time. That is a
/// fact about the platform rather than a defect; the README says so, so the
/// next person does not spend an hour on it.
final class AXAccessibilityPermissionService: AccessibilityPermissionService {
    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    var currentAuthorization: AccessibilityAuthorization {
        AXIsProcessTrusted() ? .trusted : .notTrusted
    }

    /// `kAXTrustedCheckOptionPrompt` is imported as a mutable global, which
    /// Swift 6 will not let an actor-isolated call touch. Its value is a stable
    /// part of the public API, so the string stands in for it.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    func requestTrust() -> AccessibilityAuthorization {
        let options = [Self.promptOptionKey: true] as CFDictionary
        Log.permissions.info("Requesting Accessibility trust after explicit user action")
        let trusted = AXIsProcessTrustedWithOptions(options)
        let resolved: AccessibilityAuthorization = trusted ? .trusted : .notTrusted
        Log.permissions.info("Accessibility authorization reads \(resolved.rawValue, privacy: .public) immediately after the prompt")
        return resolved
    }

    @MainActor
    func openSystemSettings() {
        guard let url = Self.privacySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
