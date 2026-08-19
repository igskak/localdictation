import Foundation

/// Accessibility trust as the application models it, decoupled from
/// `AXIsProcessTrusted` so the coordinator can be tested without the real API
/// and without a system prompt.
///
/// Two states, not four: macOS exposes no "denied" that differs from "not
/// trusted", and no restricted variant. The user either granted the app
/// Accessibility or they did not, and revoking it looks exactly like never
/// having granted it.
enum AccessibilityAuthorization: String, Sendable, Equatable, CaseIterable {
    case notTrusted
    case trusted

    var allowsInsertion: Bool { self == .trusted }
}
