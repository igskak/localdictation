import XCTest
@testable import Witness

/// The commercial rules are a pure function of a record, a license, and a date,
/// and they are tested as one. Every number the product promises appears here
/// as an assertion rather than as a sentence in a scope document.
final class EntitlementPolicyTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        firstDictationAt: Date? = nil,
        furthestSeenAt: Date? = nil
    ) -> UsageRecord {
        UsageRecord(
            installedAt: origin,
            installID: "install",
            firstDictationAt: firstDictationAt,
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

    /// Three days, and the number of times the hotkey was pressed inside them
    /// is nobody's business. The window used to end on the fifth dictation,
    /// which a real user reached in about two minutes.
    func testTheWindowIsOpenForThreeDaysHoweverMuchIsDictated() {
        XCTAssertEqual(EntitlementPolicy.ungatedDuration, 3 * 86_400)

        for elapsed in [60.0, 86_400.0, EntitlementPolicy.ungatedDuration - 1] {
            let state = EntitlementPolicy.evaluate(
                record: record(firstDictationAt: origin),
                license: nil,
                now: origin.addingTimeInterval(elapsed)
            )

            XCTAssertEqual(state, .ungated(GraceStanding(
                expiresAt: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration)
            )), "\(elapsed)s in")
            XCTAssertTrue(state.allowsDictation)
        }
    }

    func testTheFourthDayAsksForAnEmail() {
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin),
            license: nil,
            now: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration)
        )

        XCTAssertEqual(state, .locked(.activationRequired))
        XCTAssertFalse(state.allowsDictation)
    }

    /// The window is measured from the first dictation, not from installing.
    /// Somebody who downloads this on a Friday and first speaks to it on
    /// Thursday has three days from Thursday.
    func testTheWindowIsMeasuredFromTheFirstDictationRatherThanTheInstall() {
        let firstSpoke = origin.addingTimeInterval(6 * 86_400)
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: firstSpoke, furthestSeenAt: firstSpoke),
            license: nil,
            now: firstSpoke.addingTimeInterval(2 * 86_400)
        )

        XCTAssertTrue(state.allowsDictation)
    }

    // MARK: - The trial

    func testTheTrialIsTenDaysFromTheFirstDictation() {
        let started = origin
        let expiry = EntitlementPolicy.trialExpiry(firstDictationAt: started, now: started.addingTimeInterval(86_400))

        XCTAssertEqual(expiry, started.addingTimeInterval(10 * 86_400))
    }

    /// The one number this repository keeps in two languages.
    ///
    /// The app predicts the expiry date before the user hands over an address;
    /// the service decides the date that actually goes in the key. If they
    /// disagree, the app names a day the key does not honour, at the exact
    /// moment it is asking to be trusted. So the source of the other one is
    /// read here rather than remembered.
    func testTheAppAndTheServiceAgreeOnHowLongATrialIs() throws {
        let activate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Service/src/activate.js")
        let source = try String(contentsOf: activate, encoding: .utf8)

        let match = try XCTUnwrap(
            source.firstMatch(of: try Regex(#"TRIAL_SECONDS\s*=\s*(\d+)\s*\*\s*86400"#)),
            "Service/src/activate.js no longer declares TRIAL_SECONDS as a number of days"
        )
        let serviceDays = try XCTUnwrap(Int(match.output[1].substring ?? ""))

        XCTAssertEqual(
            Double(serviceDays) * 86_400,
            EntitlementPolicy.trialDuration,
            "the app predicts \(EntitlementPolicy.trialDuration / 86_400) days and the service issues \(serviceDays)"
        )
    }

    /// An activated trial outlives the three ungated days. This is the whole
    /// point of activating, and it is the assertion that would fail if the
    /// ungated deadline were ever checked ahead of the licence.
    func testATrialKeyIsHonouredPastTheUngatedWindow() {
        let expiry = origin.addingTimeInterval(EntitlementPolicy.trialDuration)
        let state = EntitlementPolicy.evaluate(
            record: record(firstDictationAt: origin),
            license: license(kind: .trial, expiresAt: expiry),
            now: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration + 86_400)
        )

        XCTAssertEqual(state.license?.kind, .trial)
        XCTAssertTrue(state.allowsDictation)
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

    /// Somebody who never activated is asked to activate, however long they
    /// have been away — never told a trial they never started has expired.
    ///
    /// This is a consequence of the window being shorter than the trial: the
    /// three-day deadline is always reached first, so the unactivated record
    /// can no longer reach the expiry branch at all. It is asserted rather than
    /// left implied, because the answer the user gets is a different sentence
    /// and a different button.
    func testAnUnactivatedRecordIsAlwaysAskedToActivateRatherThanToldItExpired() {
        let elapsedValues: [TimeInterval] = [
            EntitlementPolicy.ungatedDuration + 1,
            EntitlementPolicy.trialDuration + 1,
            365 * 86_400
        ]
        for elapsed in elapsedValues {
            let stored = record(
                firstDictationAt: origin,
                furthestSeenAt: origin.addingTimeInterval(elapsed)
            )
            let state = EntitlementPolicy.evaluate(
                record: stored,
                license: nil,
                now: origin.addingTimeInterval(elapsed)
            )

            XCTAssertEqual(state, .locked(.activationRequired), "\(elapsed)s in")
        }
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
        var stored = record(firstDictationAt: origin)
        stored.observe(now: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration + 60))

        let state = EntitlementPolicy.evaluate(record: stored, license: nil, now: origin.addingTimeInterval(3600))

        XCTAssertEqual(state.lock, .activationRequired)
    }

    /// And the other direction is left alone. A user who moves their clock
    /// forward has shortened their own trial, and pretending otherwise would
    /// mean second-guessing every daylight-saving change and time-zone move.
    func testMovingTheClockForwardIsTheUsersOwnDecision() {
        let stored = record(firstDictationAt: origin)

        let state = EntitlementPolicy.evaluate(
            record: stored,
            license: nil,
            now: origin.addingTimeInterval(EntitlementPolicy.ungatedDuration + 60)
        )

        XCTAssertEqual(state.lock, .activationRequired)
    }
}
