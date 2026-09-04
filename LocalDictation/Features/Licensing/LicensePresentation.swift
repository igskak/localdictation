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
    /// Whether the address form should be reachable even though it is not what
    /// this state leads with.
    ///
    /// A paid key is issued for a Mac, and at the moment of purchase nobody
    /// knows which Mac that is — so a license bought in a browser becomes a key
    /// on this machine only when the owner's address is handed to the service
    /// from inside the app. Without this, someone who has just paid on an
    /// expired trial sees the offers they have already taken and has nowhere to
    /// type the address they paid with.
    ///
    /// Given a default, like `StatusPresentation.showsLicenseAction`, so the
    /// states with nothing to fetch do not each have to say so.
    private(set) var offersKeyRetrieval = false
    /// What the form is called, what its button says, and the sentence under
    /// it. All three travel with the flag because which of the two errands the
    /// form is running changes all three, and copy in this file is testable.
    private(set) var activationTitle = "Activate the trial"
    private(set) var activationButtonTitle = "Send me a key"
    private(set) var activationHint = "The address and an identifier for this Mac are the only things sent, "
        + "and they are sent only when you press the button. No audio, no text, and nothing from your "
        + "dictionary ever leaves this Mac."
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
                retrieveInstead()
            case .annual:
                showsOffers = false
                headline = "Annual license"
                detail = Self.remaining(license, now: now, suffix: "Licensed to \(license.email).")
                retrieveInstead()
            case .lifetime:
                showsOffers = false
                headline = "Lifetime license"
                detail = """
                Licensed to \(license.email). This Mac needs nothing further — no renewal, and no \
                connection. It covers version \(LifetimeUpdatePolicy.coveredMajor(issuedAt: license.issuedAt)) \
                and every update to it.
                """
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
                retrieveInstead()
            case let .expired(kind, at):
                symbol = "lock"
                showsOffers = true
                showsActivation = false
                headline = "\(kind.displayName) license expired"
                detail = """
                It ran out on \(Self.moment.string(from: at)). Renewing unlocks dictation again on \
                this Mac; nothing local was removed.
                """
                retrieveInstead()

            // The one refusal in this product that is not about time. The
            // sentence has to carry the thing the user actually owns, because
            // they do own something and it still works — just not this build.
            case let .updateRequired(covered, running):
                symbol = "arrow.down.circle"
                showsOffers = true
                showsActivation = false
                headline = "This version is newer than your license"
                detail = """
                Your lifetime license covers version \(covered) and every update to it, forever. \
                This is version \(running). Download version \(covered) again from the website and \
                it works exactly as it did — or move to version \(running) below.
                """
                retrieveInstead()
            }
        }
    }

    /// Turns the form from "start a trial" into "fetch what I already own" —
    /// the same one call to the same service, a different errand.
    private mutating func retrieveInstead() {
        offersKeyRetrieval = true
        activationTitle = "Already bought a license?"
        activationButtonTitle = "Send my key"
        activationHint = "The address you bought with fetches a key for this Mac. It and an identifier "
            + "for this Mac are the only things sent, and only when you press the button — no audio, "
            + "no text, and nothing from your dictionary."
    }

    private static func remaining(_ license: License, now: Date, suffix: String) -> String {
        guard let days = license.daysRemaining(at: now), let expiresAt = license.expiresAt else { return suffix }
        return "\(Self.count(days, "day")) left, until \(Self.moment.string(from: expiresAt)). \(suffix)"
    }

    /// What to say once a key has arrived and been accepted.
    ///
    /// Worded from the licence that actually arrived, never from the errand the
    /// form thought it was running. The service decides what an address is
    /// owed, and it is routinely more than the form guessed: the wall a
    /// stranger hits is labelled "Activate the trial", and somebody who has
    /// already bought types their address into that same form and gets the
    /// annual or lifetime key they paid for.
    ///
    /// It said "the trial runs for fourteen days" to a paying customer holding
    /// a year, which is the kind of sentence that makes a person check whether
    /// their money arrived.
    static func activationSucceeded(_ kind: LicenseKind?) -> String {
        switch kind {
        case .trial:
            "Activated. The trial runs for fourteen days from your first dictation."
        case .annual:
            "Your annual license is on this Mac now."
        case .lifetime:
            "Your lifetime license is on this Mac now. Nothing further is needed here — no renewal, and no connection."
        case nil:
            "The key for this Mac was accepted."
        }
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
