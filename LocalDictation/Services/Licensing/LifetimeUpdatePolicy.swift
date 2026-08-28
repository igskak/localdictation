import Foundation

/// What "lifetime" was sold as.
///
/// `docs/PHASE_8_DECISIONS.md` D6: **the purchased major version and every
/// minor update to it.** It is the only reading under which the seller can keep
/// shipping and the buyer can tell, before paying, what they are buying — and
/// the word is never used in this product to mean a duration of time.
///
/// The rule is a pure function of two things the app already has: the date in
/// the key's payload, and the version it is running. It reads no network and
/// asks nobody. A lifetime licence keeps working on a plane, at a customer
/// site, and after this project's servers are gone, which is the whole reason
/// Phase 6 made a licence a signature.
///
/// **Today it decides nothing**, and a test says so. There has only ever been
/// one major version, so every lifetime licence ever issued covers the version
/// in front of it. The table below is what turns it on, one row at a time, and
/// the rows are facts rather than decisions: the day a major version was first
/// available for download.
enum LifetimeUpdatePolicy {
    /// The first major version. Every licence ever issued is covered by at
    /// least this one, which is why it needs no date — there was no earlier
    /// version anybody could have bought.
    static let firstMajor = 1

    /// The day each *later* major version was first available.
    ///
    /// Append a row when a major ships. **Never edit one**: the date is what
    /// decides which licences bought before it keep their entitlement, and
    /// moving it retroactively takes something away from somebody who paid.
    static let laterMajors: [(major: Int, releasedAt: Date)] = []

    /// The highest major version a licence issued on this date paid for.
    static func coveredMajor(issuedAt: Date) -> Int {
        var covered = firstMajor
        for release in laterMajors where release.releasedAt <= issuedAt {
            covered = max(covered, release.major)
        }
        return covered
    }

    /// The major component of a marketing version like `1.4.2`.
    ///
    /// A version this cannot read is treated as the first major rather than as
    /// a failure: a licence is not the place to be strict about a string in a
    /// plist that the user did not write.
    static func major(of version: String) -> Int {
        Int(version.split(separator: ".").first ?? "") ?? firstMajor
    }

    /// Where a licence stands against the version it is being asked to unlock.
    enum Standing: Sendable, Equatable {
        /// Not a lifetime licence, so this rule has nothing to say.
        case notApplicable
        /// The running version is inside what was bought.
        case covered(major: Int)
        /// The running version is a major beyond what was bought. The purchased
        /// major keeps working forever; this build is not it.
        case superseded(covered: Int, running: Int)
    }

    static func standing(for license: License, runningVersion: String = AppVersion.short) -> Standing {
        guard license.kind == .lifetime else { return .notApplicable }
        let covered = coveredMajor(issuedAt: license.issuedAt)
        let running = major(of: runningVersion)
        guard running > covered else { return .covered(major: covered) }
        return .superseded(covered: covered, running: running)
    }

    /// The sentence a buyer reads in Settings, before they are ever in a
    /// position to be surprised by it.
    ///
    /// It reads the same table the enforcement does, and asks it the same
    /// question — what would a licence bought right now cover — rather than
    /// reading the running version. Those are the same number in every case
    /// that matters, and they differ in the one that does not: a pre-1.0 build
    /// is version 0, and "covers version 0" is not a promise anybody would make.
    static func promise(at now: Date = Date()) -> String {
        "Paid once. Covers two Macs, and version \(coveredMajor(issuedAt: now)) with every update to it."
    }
}
