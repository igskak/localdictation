import XCTest
@testable import Witness

/// The commercial rules are a pure function of a record, a license, and a date,
/// and they are tested as one. Every number the product promises appears here
/// as an assertion rather than as a sentence in a scope document.
final class EntitlementPolicyTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        firstDictationAt: Date? = nil,
        successfulDictations: Int = 0,
        furthestSeenAt: Date? = nil
    ) -> UsageRecord {
        UsageRecord(
            installedAt: origin,
            installID: "install",
            firstDictationAt: firstDictationAt,
            successfulDictations: successfulDictations,
            furthestSeenAt: furthestSeenAt ?? origin,
            licenseToken: nil
        )
    }

    private func license(kind: LicenseKind, expiresAt: Date?) -> License {
        License(
            id: "lic",
            email: "owner@example.com",
            kind: kind,
            deviceID: "device",
            issuedAt: origin,
            expiresAt: expiresAt
        )
    }

    // MARK: - The ungated window

    /// The download is never gated, and neither is opening the app. Until the
    /// first dictation the app has nothing to charge for and asks for nothing.
    func testNothingIsAskedForBeforeTheFirstDictation() {
        let state = EntitlementPolicy.evaluate(record: record(), license: nil, now: origin)

        XCTAssertEqual(state, .ungated(.untouched))
        XCTAssertTrue(state.allowsDictation)
    }

    func testTheFifthDictationIsStillFree() {
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin, successfulDictations: 4),
            license: nil,
            now: origin.addingTimeInterval(60)
        )

        XCTAssertEqual(state, .ungated(GraceStanding(
            dictationsRemaining: 1,
            expiresAt: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration)
        )))
    }

    func testTheSixthAsksForAnEmail() {
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin, successfulDictations: 5),
            license: nil,
            now: origin.addingTimeInterval(60)
        )

        XCTAssertEqual(state, .locked(.activationRequired))
        XCTAssertFalse(state.allowsDictation)
    }

    /// The other half of "whichever comes first": two dictations in a day is
    /// well inside the count and still outside the window.
    func testTwentyFourHoursCloseTheWindowOnItsOwn() {
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin, successfulDictations: 2),
            license: nil,
            now: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration + 1)
        )

        XCTAssertEqual(state, .locked(.activationRequired))
    }

    // MARK: - The trial

    /// An activated trial is fourteen days from the first dictation, not from
    /// the activation — otherwise deleting a file buys another two weeks.
    func testTheTrialRunsFromTheFirstDictation() {
        let started = origin
        let expiry = EntitlementPolicy.trialExpiry(firstDictationAt: started, now: started.addingTimeInterval(86_400))

        XCTAssertEqual(expiry, started.addingTimeInterval(14 * 86_400))
    }

    func testATrialKeyIsHonouredForItsWholeTerm() {
        let expiry = origin.addingTimeInterval(EntitlementPolicy.trialDuration)
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin, successfulDictations: 99),
            license: license(kind: .trial, expiresAt: expiry),
            now: origin.addingTimeInterval(13 * 86_400)
        )

        XCTAssertEqual(state.license?.kind, .trial)
        XCTAssertTrue(state.allowsDictation, "the count only governs the ungated window, never an activated trial")
    }

    func testTheTrialEndsOnItsDate() {
        let expiry = origin.addingTimeInterval(EntitlementPolicy.trialDuration)
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin),
            license: license(kind: .trial, expiresAt: expiry),
            now: expiry
        )

        XCTAssertEqual(state, .locked(.expired(.trial, at: expiry)))
    }

    /// The unactivated case, where there is no key to carry the date and the
    /// record has to. Fourteen days is fourteen days either way.
    func testAnUnactivatedTrialAlsoEndsAtFourteenDays() {
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin, successfulDictations: 1),
            license: nil,
            now: origin.addingTimeInterval(EntitlementPolicy.trialDuration + 1)
        )

        XCTAssertEqual(state, .locked(.expired(.trial, at: origin.addingTimeInterval(EntitlementPolicy.trialDuration))))
    }

    // MARK: - Licenses

    func testALifetimeLicenseNeverExpires() {
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin),
            license: license(kind: .lifetime, expiresAt: nil),
            now: origin.addingTimeInterval(40 * 365 * 86_400)
        )

        XCTAssertEqual(state.license?.kind, .lifetime)
    }

    func testAnAnnualLicenseLapsesAndSaysWhen() {
        let expiry = origin.addingTimeInterval(365 * 86_400)
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin),
            license: license(kind: .annual, expiresAt: expiry),
            now: expiry.addingTimeInterval(1)
        )

        XCTAssertEqual(state, .locked(.expired(.annual, at: expiry)))
        XCTAssertTrue(state.wantsPurchase)
    }

    // MARK: - The clock

    /// Setting the Mac's clock back is the oldest trick there is, and the
    /// defence is one line: time is measured from the furthest point the app
    /// has ever seen.
    func testMovingTheClockBackReturnsNothing() {
        var stored = record(firstDictationAt: origin, successfulDictations: 1)
        stored.observe(now: origin.addingTimeInterval(EntitlementPolicy.trialDuration + 60))

        let state = EntitlementPolicy.evaluate(record: stored, license: nil, now: origin.addingTimeInterval(3600))

        XCTAssertEqual(state.lock, .expired(.trial, at: origin.addingTimeInterval(EntitlementPolicy.trialDuration)))
    }

    /// And the other direction is left alone. A user who moves their clock
    /// forward has shortened their own trial, and pretending otherwise would
    /// mean second-guessing every daylight-saving change and time-zone move.
    func testMovingTheClockForwardIsTheUsersOwnDecision() {
        let stored = record(firstDictationAt: origin, successfulDictations: 1)

        let state = EntitlementPolicy.evaluate(
            record: stored,
            license: nil,
            now: origin.addingTimeInterval(EntitlementPolicy.trialDuration + 60)
        )

        XCTAssertEqual(state.lock, .expired(.trial, at: origin.addingTimeInterval(EntitlementPolicy.trialDuration)))
    }
}
