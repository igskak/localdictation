import Foundation

/// Everything the app has counted since it was installed.
///
/// This is the whole of the second file the app writes, and it is deliberately
/// small enough to read in one breath: an install identifier, four facts about
/// time and use, and the key the user entered. A test asserts the encoded form holds nothing else,
/// the way `GlossaryTests` does for the dictionary.
struct UsageRecord: Codable, Sendable, Equatable {
    var installedAt: Date
    /// A random value made once, at install. It identifies this copy of the app
    /// for funnel counting and is derived from nothing — not the Mac, not the
    /// user, not the license — so it cannot be joined to anything outside this
    /// product. See `TelemetryEnvelope`.
    var installID: String
    /// When the trial clock started. `nil` until the app has produced text.
    var firstDictationAt: Date?
    /// The furthest point in time this Mac has ever been seen at.
    ///
    /// Not a diagnostic: it is the whole clock-tampering defence. Elapsed time
    /// is measured from `max(now, furthestSeenAt)`, so setting the clock back
    /// returns nothing, and setting it forward is a decision the user has taken
    /// about their own trial.
    var furthestSeenAt: Date
    /// The signed token exactly as the user entered it. Re-verified on every
    /// launch rather than trusted because it is on disk.
    var licenseToken: String?

    static func new(at now: Date) -> UsageRecord {
        UsageRecord(
            installedAt: now,
            installID: UUID().uuidString,
            firstDictationAt: nil,
            furthestSeenAt: now,
            licenseToken: nil
        )
    }

    /// Advances the tamper guard. Always call before evaluating.
    mutating func observe(now: Date) {
        if now > furthestSeenAt { furthestSeenAt = now }
    }

    func effectiveNow(_ now: Date) -> Date { max(now, furthestSeenAt) }
}

/// The commercial rules, as numbers in one place and a pure function over them.
///
/// Nothing here touches the disk, the clock, or the network, so every rule the
/// product promises is decided by a function a test can call with a date.
enum EntitlementPolicy {
    /// Three days before the app asks for anything, measured from the first
    /// successful dictation.
    ///
    /// It used to be five dictations or 24 hours, whichever came first, and the
    /// count is what went wrong: a dictation is a whole utterance, so a real
    /// user spent all five in one conversation and met the wall about two
    /// minutes in — before they had formed an opinion worth trading an address
    /// for. Three days is the same ask moved to a point where the product has
    /// already been useful. `docs/REFINEMENTS.md` records why.
    ///
    /// There is deliberately no dictation count any more. Two ways to end the
    /// same window meant two sentences to write, two thresholds to warn on, and
    /// a countdown in the menu bar that measured presses while the user was
    /// thinking in days.
    static let ungatedDuration: TimeInterval = 3 * 86_400
    /// The ten days an activated trial runs for, measured from the first
    /// successful dictation rather than from installation: a download someone
    /// opened once and came back to a week later has not had a trial.
    ///
    /// **This number and `TRIAL_SECONDS` in `Service/src/activate.js` are one
    /// decision in two languages.** The service decides the date that goes in
    /// the key; this constant is what lets the app name that date *before* the
    /// user hands over their address, and an app that predicts fourteen while
    /// the service issues ten lies at the exact moment it is asking to be
    /// trusted. `EntitlementPolicyTests.testTheAppAndTheServiceAgreeOnHowLongATrialIs`
    /// reads the service's own source and fails when they drift.
    ///
    /// Three days ungated plus ten activated is thirteen. The service issues
    /// its ten from the moment of activation and does not know the date of the
    /// first dictation, so somebody who activates late gets slightly more —
    /// which is the right way round for that error to fall. `docs/PHASE_8.md`.
    static let trialDuration: TimeInterval = 10 * 86_400

    /// The one decision. `license` is already verified — signature and device
    /// are the key reader's job, not the policy's.
    ///
    /// `runningVersion` is a parameter rather than a lookup so this stays a pure
    /// function of its arguments. It is only read for a lifetime license, and
    /// only because of what "lifetime" was sold as — see `LifetimeUpdatePolicy`.
    static func evaluate(
        record: UsageRecord,
        license: License?,
        now: Date,
        runningVersion: String = AppVersion.short
    ) -> EntitlementState {
        let now = record.effectiveNow(now)

        if let license {
            if license.isExpired(at: now) {
                return .locked(.expired(license.kind, at: license.expiresAt ?? now))
            }
            if case let .superseded(covered, running) = LifetimeUpdatePolicy.standing(
                for: license,
                runningVersion: runningVersion
            ) {
                return .locked(.updateRequired(coveredMajor: covered, runningMajor: running))
            }
            return .licensed(license)
        }

        guard let started = record.firstDictationAt else {
            // Nothing has been dictated yet, so nothing has been spent. The
            // clock does not start on launch, and the app asks for nothing.
            return .ungated(.untouched)
        }

        // Deliberately no "the trial expired" branch here. Without a key there
        // is no trial to expire: this record belongs to somebody who dictated,
        // never gave an address, and came back. The service will still issue
        // them a trial — neither their address nor their Mac has taken one —
        // so telling them their trial is over would hide an offer that is
        // still open and lead the paywall with a price instead of the form.
        //
        // This used to be checked first, and it was reachable: three ungated
        // days are shorter than ten trial days, so anybody returning after a
        // fortnight was told their trial had run out. They had never had one.
        let deadline = started.addingTimeInterval(ungatedDuration)
        if now >= deadline {
            return .locked(.activationRequired)
        }

        return .ungated(GraceStanding(expiresAt: deadline))
    }

    /// When a trial key issued now should expire.
    ///
    /// The issuer decides the date, but the app has to be able to say what it
    /// will be before the user hands over their address — an activation that
    /// silently resets the ten days would be a different product, and one
    /// that rewards deleting a file.
    static func trialExpiry(firstDictationAt: Date?, now: Date) -> Date {
        (firstDictationAt ?? now).addingTimeInterval(trialDuration)
    }
}
