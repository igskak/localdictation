import Foundation

enum ActivationError: Error, Sendable, Equatable {
    /// No activation endpoint is compiled into this build.
    case notConfigured
    case invalidEmail
    case unreachable(String)
    case rejected(String)
    /// The license already covers two Macs.
    case deviceLimitReached

    var message: String {
        switch self {
        case .notConfigured:
            "This build has no activation service. Paste a license key instead, or use a build from the product website."
        case .invalidEmail:
            "That address does not look complete. The key is sent to it, so a typo means it goes nowhere."
        case let .unreachable(detail):
            "The activation service could not be reached: \(detail). Your dictation still works until the trial window closes."
        case let .rejected(detail):
            detail
        case .deviceLimitReached:
            "This license already covers two Macs. Release one of them before activating a third."
        }
    }
}

/// The one place the app is allowed to talk to a server, and the only thing it
/// is allowed to say.
///
/// The request carries an email address the user typed and the salted device
/// hash, and nothing else — no audio, no text, no vocabulary, no application
/// names, no counters derived from what was dictated. That list is the whole
/// contract, it is enumerated in `docs/PHASE_6.md`, and it is narrow enough
/// that a reviewer can check it against this signature.
protocol ActivationBackend: Sendable {
    var isConfigured: Bool { get }
    /// Returns a signed key for this Mac, or throws something the user can act on.
    func requestKey(email: String, deviceID: String) async throws -> String
}

/// What a build ships with until there is a service to talk to.
///
/// It refuses instead of pretending, which keeps the manual key path — the one
/// that works today — the visible one. A stub that silently succeeded would
/// make every activation test pass and the product ship broken.
struct UnconfiguredActivationBackend: ActivationBackend {
    var isConfigured: Bool { false }

    func requestKey(email: String, deviceID: String) async throws -> String {
        throw ActivationError.notConfigured
    }
}

enum EmailAddress {
    /// Deliberately permissive. The address is checked by the thing that sends
    /// mail to it; a regular expression here can only reject valid addresses
    /// that someone actually owns.
    static func looksComplete(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        guard !domain.contains("@") else { return false }
        guard let dot = domain.firstIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) < domain.endIndex && !trimmed.contains(" ")
    }
}
