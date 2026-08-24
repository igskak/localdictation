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
    /// Successful dictations only — a press that recognized nothing has not
    /// spent anything and must not cost the user part of their window.
    var successfulDictations: Int
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
            successfulDictations: 0,
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
    /// `docs/PRODUCT_SCOPE.md`: the download is never gated, and activation is
    /// required after the initial five dictations or 24 hours from the first
    /// successful one, whichever comes first.
    static let ungatedDictations = 5
    static let ungatedDuration: TimeInterval = 24 * 3600
    /// The fourteen-day full trial, measured from the first successful
    /// dictation rather than from installation: a download someone opened once
    /// and came back to a week later has not had a trial.
    static let trialDuration: TimeInterval = 14 * 86_400

    /// The one decision. `license` is already verified — signature and device
    /// are the key reader's job, not the policy's.
    static func evaluate(record: UsageRecord, license: License?, now: Date) -> EntitlementState {
        let now = record.effectiveNow(now)

        if let license {
            if license.isExpired(at: now) {
                return .locked(.expired(license.kind, at: license.expiresAt ?? now))
            }
            return .licensed(license)
        }

        guard let started = record.firstDictationAt else {
            // Nothing has been dictated yet, so nothing has been spent. The
            // clock does not start on launch, and the app asks for nothing.
            return .ungated(.untouched)
        }

        let elapsed = now.timeIntervalSince(started)
        if elapsed >= trialDuration {
            return .locked(.expired(.trial, at: started.addingTimeInterval(trialDuration)))
        }

        let dictationsRemaining = max(ungatedDictations - record.successfulDictations, 0)
        let deadline = started.addingTimeInterval(ungatedDuration)
        if dictationsRemaining == 0 || now >= deadline {
            return .locked(.activationRequired)
        }

        return .ungated(GraceStanding(dictationsRemaining: dictationsRemaining, expiresAt: deadline))
    }

    /// When a trial key issued now should expire.
    ///
    /// The issuer decides the date, but the app has to be able to say what it
    /// will be before the user hands over their address — an activation that
    /// silently resets the fourteen days would be a different product, and one
    /// that rewards deleting a file.
    static func trialExpiry(firstDictationAt: Date?, now: Date) -> Date {
        (firstDictationAt ?? now).addingTimeInterval(trialDuration)
    }
}
