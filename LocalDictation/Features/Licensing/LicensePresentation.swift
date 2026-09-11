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
    private(set) var activationTitle = L10n.string("Activate the trial")
    private(set) var activationButtonTitle = L10n.string("Send me a key")
    /// Two jobs, and the second one is newer than the first.
    ///
    /// The privacy sentence has been here since Phase 6. The sentence after it
    /// exists because the button says "Send me a key", which is a promise of
    /// something arriving in the post — so a user reasonably expects to have to
    /// go and fetch it. They do not: the key comes back on the same connection
    /// and unlocks the app before the mail is even sent. Saying so here costs a
    /// line and saves the person who would otherwise sit waiting for an email
    /// in order to use software that is already working.
    private(set) var activationHint = L10n.string("The key comes straight back here and unlocks the app — there is nothing to fetch from your mail and nothing to paste. The address and an identifier for this Mac are the only things sent, and they are sent only when you press the button. No audio, no text, and nothing from your dictionary ever leaves this Mac.")
    let symbol: String

    init(state: EntitlementState, now: Date = Date()) {
        switch state {
        case let .ungated(standing):
            symbol = "hand.wave"
            showsOffers = false
            showsActivation = true
            if let expiresAt = standing.expiresAt {
                headline = L10n.string("Trial, not yet activated")
                detail = L10n.format("Nothing is asked for until %@. Adding your email after that adds ten more days, free.", Self.moment.string(from: expiresAt))
            } else {
                headline = L10n.string("Ready to use, nothing asked for yet")
                detail = L10n.string("The first three days need no email and no key. After that, an email keeps the trial running for ten more days.")
            }

        case let .licensed(license):
            symbol = license.kind == .lifetime ? "checkmark.seal" : "clock.badge.checkmark"
            showsActivation = false
            switch license.kind {
            case .trial:
                showsOffers = true
                headline = L10n.string("Trial, activated")
                detail = Self.remaining(license, now: now, suffix: L10n.string("A license keeps it after that, on this Mac and one more."))
                retrieveInstead()
            case .annual:
                showsOffers = false
                headline = L10n.string("Annual license")
                detail = Self.remaining(license, now: now, suffix: L10n.format("Licensed to %@.", license.email))
                retrieveInstead()
            case .lifetime:
                showsOffers = false
                headline = L10n.string("Lifetime license")
                detail = L10n.format(
                    "Licensed to %1$@. This Mac needs nothing further — no renewal, and no connection. It covers version %2$lld and every update to it.",
                    license.email,
                    Int64(LifetimeUpdatePolicy.coveredMajor(issuedAt: license.issuedAt))
                )
            }

        case let .locked(lock):
            switch lock {
            case .activationRequired:
                symbol = "envelope"
                showsOffers = false
                showsActivation = true
                headline = L10n.string("Activate to keep dictating")
                detail = L10n.string("The first three days are over. An email address gets you a key for this Mac and ten full days; nothing else about the app changes, and nothing you have dictated has left it.")
            case let .expired(.trial, at):
                symbol = "lock"
                showsOffers = true
                showsActivation = false
                headline = L10n.string("The trial ended")
                detail = L10n.format("Fourteen days ran out on %@. Your dictionary and settings are untouched and come straight back with a license.", Self.moment.string(from: at))
                retrieveInstead()
            case let .expired(kind, at):
                symbol = "lock"
                showsOffers = true
                showsActivation = false
                headline = L10n.format("%@ license expired", kind.displayName)
                detail = L10n.format("It ran out on %@. Renewing unlocks dictation again on this Mac; nothing local was removed.", Self.moment.string(from: at))
                retrieveInstead()

            // The one refusal in this product that is not about time. The
            // sentence has to carry the thing the user actually owns, because
            // they do own something and it still works — just not this build.
            case let .updateRequired(covered, running):
                symbol = "arrow.down.circle"
                showsOffers = true
                showsActivation = false
                headline = L10n.string("This version is newer than your license")
                detail = L10n.format(
                    "Your lifetime license covers version %1$lld and every update to it, forever. This is version %2$lld. Download version %1$lld again from the website and it works exactly as it did — or move to version %2$lld below.",
                    Int64(covered),
                    Int64(running)
                )
                retrieveInstead()
            }
        }
    }

    /// Turns the form from "start a trial" into "fetch what I already own" —
    /// the same one call to the same service, a different errand.
    private mutating func retrieveInstead() {
        offersKeyRetrieval = true
        activationTitle = L10n.string("Already bought a license?")
        activationButtonTitle = L10n.string("Send my key")
        activationHint = L10n.string("The address you bought with fetches a key for this Mac. It and an identifier for this Mac are the only things sent, and only when you press the button — no audio, no text, and nothing from your dictionary.")
    }

    private static func remaining(_ license: License, now: Date, suffix: String) -> String {
        guard let days = license.daysRemaining(at: now), let expiresAt = license.expiresAt else { return suffix }
        return L10n.format("%1$@ left, until %2$@. %3$@", Self.count(days, "day"), Self.moment.string(from: expiresAt), suffix)
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
    ///
    /// The trial sentence was wrong in a second way, and it is fixed here: it
    /// said the days ran "from your first dictation", and they never did. The
    /// service issues them from the moment of activation and does not know the
    /// date of the first dictation — `docs/PHASE_8.md` froze the request at two
    /// fields on purpose. While the ungated window was 24 hours the gap was too
    /// small to notice; at three days it is a sentence the user can catch out.
    ///
    /// Each of these says the same first thing in its own words: **it is
    /// already done, and there is nothing to type.** A user who has just been
    /// refused, typed an address, and then gets a mail containing a long
    /// `LD1.…` string has every reason to think the string is the next step.
    /// It is not — the key came back over the same connection and is already
    /// stored. `keyByMailNote` is what the mail is actually for.
    static func activationSucceeded(_ kind: LicenseKind?) -> String {
        switch kind {
        case .trial:
            L10n.string("Activated, and there is nothing else to enter. The trial runs for ten days from today.")
        case .annual:
            L10n.string("Your annual license is on this Mac now. There is nothing else to enter.")
        case .lifetime:
            L10n.string("Your lifetime license is on this Mac now. There is nothing else to enter — no renewal, and no connection.")
        case nil:
            L10n.string("The key for this Mac was accepted.")
        }
    }

    /// What the emailed copy of the key is for, said where the user is looking
    /// rather than left to be worked out from the mail itself.
    ///
    /// Two things in it are load-bearing and both are chosen to be true even
    /// when the mail does not arrive:
    ///
    /// - It says the copy is *going*, not that it was delivered. This app never
    ///   learns whether it was: the reply to an activation is a key and nothing
    ///   else, and `Service/src/activate.js` mails on a best effort, only for a
    ///   device slot that has not been mailed before.
    /// - It says what to do if it never comes, and the answer is genuinely
    ///   nothing to worry about: `issueToken` is deterministic, so the same
    ///   address on the same Mac returns the identical key, and the service
    ///   retries the mail on that press because the slot is still unmailed.
    ///
    /// It is shown only after an activation. Entering a key by hand sends no
    /// mail, and promising one there would be a sentence about something that
    /// did not happen.
    static var keyByMailNote: String {
        L10n.string("A copy of the key is also on its way to that address. You do not need it now — it is for when you reinstall Witness or replace this Mac. If it never arrives, press the button again: the same key comes back here and the mail is retried.")
    }

    /// "1 day", "5 days". Small, and the alternative is a string with a
    /// parenthesised plural in it.
    static func count(_ value: Int, _ noun: String) -> String {
        if noun == "day" {
            return value == 1
                ? L10n.format("%lld day", Int64(value))
                : L10n.format("%lld days", Int64(value))
        }
        return "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private static let moment: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
