import Foundation

/// Pure mapping from the licensing state to the words the user reads, so the
/// wording can be tested without a view — the same arrangement
/// `StatusPresentation` uses, and for the same reason: this copy is the product
/// in the states where nothing else is visible.
struct LicensePresentation: Sendable, Equatable {
    /// One line, in the user's terms, about where they stand.
    let headline: String
    /// The sentence under it. Says what happens next, never what went wrong.
    let detail: String
    /// Whether to lead with the offers rather than with activation.
    let showsOffers: Bool
    /// Whether the email-for-a-key form is the thing to do now.
    let showsActivation: Bool
    let symbol: String

    init(state: EntitlementState, now: Date = Date()) {
        switch state {
        case let .ungated(standing):
            symbol = "hand.wave"
            showsOffers = false
            showsActivation = true
            if let expiresAt = standing.expiresAt {
                headline = "Trial, not yet activated"
                detail = """
                \(Self.count(standing.dictationsRemaining, "dictation")) left before activation, \
                or until \(Self.moment.string(from: expiresAt)) — whichever comes first. \
                Adding your email turns this into the full fourteen days.
                """
            } else {
                headline = "Ready to use, nothing asked for yet"
                detail = """
                The first \(EntitlementPolicy.ungatedDictations) dictations need no email and no key. \
                After that — or 24 hours after the first one — an email keeps the trial \
                running for fourteen days.
                """
            }

        case let .licensed(license):
            symbol = license.kind == .lifetime ? "checkmark.seal" : "clock.badge.checkmark"
            showsActivation = false
            switch license.kind {
            case .trial:
                showsOffers = true
                headline = "Trial, activated"
                detail = Self.remaining(license, now: now, suffix: "A license keeps it after that, on this Mac and one more.")
            case .annual:
                showsOffers = false
                headline = "Annual license"
                detail = Self.remaining(license, now: now, suffix: "Licensed to \(license.email).")
            case .lifetime:
                showsOffers = false
                headline = "Lifetime license"
                detail = "Licensed to \(license.email). This Mac needs nothing further — no renewal, and no connection."
            }

        case let .locked(lock):
            switch lock {
            case .activationRequired:
                symbol = "envelope"
                showsOffers = false
                showsActivation = true
                headline = "Activate to keep dictating"
                detail = """
                The ungated window is used up. An email address gets you a key for this Mac and \
                fourteen full days; nothing else about the app changes, and nothing you have \
                dictated has left it.
                """
            case let .expired(.trial, at):
                symbol = "lock"
                showsOffers = true
                showsActivation = false
                headline = "The trial ended"
                detail = """
                Fourteen days ran out on \(Self.moment.string(from: at)). Your dictionary and \
                settings are untouched and come straight back with a license.
                """
            case let .expired(kind, at):
                symbol = "lock"
                showsOffers = true
                showsActivation = false
                headline = "\(kind.displayName) license expired"
                detail = """
                It ran out on \(Self.moment.string(from: at)). Renewing unlocks dictation again on \
                this Mac; nothing local was removed.
                """
            }
        }
    }

    private static func remaining(_ license: License, now: Date, suffix: String) -> String {
        guard let days = license.daysRemaining(at: now), let expiresAt = license.expiresAt else { return suffix }
        return "\(Self.count(days, "day")) left, until \(Self.moment.string(from: expiresAt)). \(suffix)"
    }

    /// "1 day", "5 days". Small, and the alternative is a string with a
    /// parenthesised plural in it.
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private static let moment: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
