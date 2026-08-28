import XCTest
@testable import LocalDictation

/// What the word "lifetime" was sold as, as a function.
///
/// `docs/PHASE_8_DECISIONS.md` D6: the purchased major version and every minor
/// update to it. The rule matters long before it fires — a buyer has to be able
/// to tell what they are getting *before* they pay — so it is written, tested,
/// and inert, rather than written on the day it first takes something away from
/// somebody.
final class LifetimeUpdatePolicyTests: XCTestCase {
    private let issued = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01

    private func lifetime(issuedAt: Date) -> License {
        License(
            id: "id",
            email: "owner@example.com",
            kind: .lifetime,
            deviceID: "0123456789abcdef0123456789abcdef",
            issuedAt: issuedAt,
            expiresAt: nil
        )
    }

    /// The assertion that keeps this honest. There has only ever been one major
    /// version, so no licence anybody holds is behind anything, and shipping
    /// this rule changes nothing for anyone today.
    func testTodayThisRuleDecidesNothing() {
        XCTAssertTrue(LifetimeUpdatePolicy.laterMajors.isEmpty)
        XCTAssertEqual(LifetimeUpdatePolicy.coveredMajor(issuedAt: issued), LifetimeUpdatePolicy.firstMajor)
        XCTAssertEqual(
            LifetimeUpdatePolicy.standing(for: lifetime(issuedAt: issued), runningVersion: "1.9.3"),
            .covered(major: 1)
        )
    }

    func testEveryMinorUpdateToThePurchasedMajorIsCovered() {
        for version in ["1.0.0", "1.2.0", "1.14.7"] {
            XCTAssertEqual(
                LifetimeUpdatePolicy.standing(for: lifetime(issuedAt: issued), runningVersion: version),
                .covered(major: 1),
                "version \(version)"
            )
        }
    }

    /// The rule, exercised against a table that does not exist yet. The
    /// arithmetic is what will be shipped; the rows are the only thing missing.
    func testAMajorReleasedAfterThePurchaseIsNotCovered() {
        let standing = LifetimeUpdatePolicy.standing(for: lifetime(issuedAt: issued), runningVersion: "2.0.0")
        XCTAssertEqual(standing, .superseded(covered: 1, running: 2))
    }

    func testAVersionThatCannotBeReadIsTreatedAsTheFirstMajorRatherThanAsAFailure() {
        XCTAssertEqual(LifetimeUpdatePolicy.major(of: ""), 1)
        XCTAssertEqual(LifetimeUpdatePolicy.major(of: "unknown"), 1)
        XCTAssertEqual(LifetimeUpdatePolicy.major(of: "0.1.0"), 0)
        XCTAssertEqual(LifetimeUpdatePolicy.major(of: "12.4"), 12)
    }

    /// Dated licences are somebody else's rule. A trial on a newer major is
    /// governed by its date, and saying two things about it would be one thing
    /// too many.
    func testThisSaysNothingAboutADatedLicense() {
        let annual = License(
            id: "id",
            email: "owner@example.com",
            kind: .annual,
            deviceID: "0123456789abcdef0123456789abcdef",
            issuedAt: issued,
            expiresAt: issued.addingTimeInterval(365 * 86_400)
        )
        XCTAssertEqual(LifetimeUpdatePolicy.standing(for: annual, runningVersion: "9.0.0"), .notApplicable)
    }

    /// The offer names the version it covers, so nothing about this is a
    /// discovery after a purchase.
    func testTheOfferSaysWhatItCovers() {
        XCTAssertEqual(
            LifetimeUpdatePolicy.promise(at: issued),
            "Paid once. Covers two Macs, and version 1 with every update to it."
        )
    }

    // MARK: - What it does to the gate

    func testALifetimeLicenseOnAMajorItDidNotBuyLocksWithItsOwnSentence() {
        var record = UsageRecord.new(at: issued)
        record.firstDictationAt = issued
        record.successfulDictations = 20

        let state = EntitlementPolicy.evaluate(
            record: record,
            license: lifetime(issuedAt: issued),
            now: issued.addingTimeInterval(86_400),
            runningVersion: "2.0.0"
        )

        XCTAssertEqual(state, .locked(.updateRequired(coveredMajor: 1, runningMajor: 2)))
        XCTAssertFalse(state.allowsDictation)
        XCTAssertTrue(state.wantsPurchase)

        let presentation = LicensePresentation(state: state)
        XCTAssertTrue(presentation.showsOffers)
        XCTAssertTrue(presentation.offersKeyRetrieval, "the address they bought with is how they get the newer key")
        XCTAssertTrue(presentation.detail.contains("version 1"))
        XCTAssertTrue(presentation.detail.contains("forever"))
    }

    func testTheSameLicenseOnTheVersionItBoughtIsSimplyLicensed() {
        var record = UsageRecord.new(at: issued)
        record.firstDictationAt = issued
        record.successfulDictations = 20

        let state = EntitlementPolicy.evaluate(
            record: record,
            license: lifetime(issuedAt: issued),
            now: issued.addingTimeInterval(86_400),
            runningVersion: "1.7.0"
        )

        XCTAssertEqual(state.license?.kind, .lifetime)
        XCTAssertTrue(state.allowsDictation)
    }

    /// The lock has to be one the funnel can name, like every other one.
    func testTheLockCarriesItsOwnPaywallTrigger() {
        XCTAssertEqual(EntitlementLock.updateRequired(coveredMajor: 1, runningMajor: 2).paywallTrigger, .updateRequired)
    }
}
