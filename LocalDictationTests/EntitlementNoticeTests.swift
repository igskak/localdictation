import XCTest
@testable import Witness

/// The warning before the wall.
///
/// Two halves to this: it has to appear while the user can still act, and it
/// has to be absent every other time. The second half is the one that decays if
/// nobody asserts it, and a permanent countdown in a menu bar is how a paid
/// product starts feeling like a nag.
final class EntitlementNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Silence

    func testAMacThatHasNotDictatedIsToldNothing() {
        XCTAssertNil(EntitlementNotice(state: .ungated(.untouched), now: now))
    }

    func testALifetimeLicenseIsNeverNagged() {
        let license = makeLicense(kind: .lifetime, expiresAt: nil)
        XCTAssertNil(EntitlementNotice(state: .licensed(license), now: now))
    }

    func testATrialWithARoomyWeekLeftSaysNothing() {
        let license = makeLicense(kind: .trial, expiresAt: now.addingTimeInterval(7 * 86_400))
        XCTAssertNil(EntitlementNotice(state: .licensed(license), now: now))
    }

    func testAnAnnualLicenseIsQuietUntilItsLastFortnight() {
        let far = makeLicense(kind: .annual, expiresAt: now.addingTimeInterval(60 * 86_400))
        XCTAssertNil(EntitlementNotice(state: .licensed(far), now: now))

        let near = makeLicense(kind: .annual, expiresAt: now.addingTimeInterval(10 * 86_400))
        XCTAssertNotNil(EntitlementNotice(state: .licensed(near), now: now))
    }

    /// The lock view already says this, with the same words. Two boxes making
    /// the same point is worse than one.
    func testALockedMacIsLeftToTheLockView() {
        XCTAssertNil(EntitlementNotice(state: .locked(.activationRequired), now: now))
        XCTAssertNil(EntitlementNotice(state: .locked(.expired(.trial, at: now)), now: now))
    }

    // MARK: - The ungated window

    /// Days one and two say nothing at all. The window is only three days
    /// wide, so a notice with the trial's own three-day threshold would be on
    /// screen from the first minute — which this file exists to argue against.
    func testTheFirstTwoDaysSayNothing() {
        for remaining in [3 * 86_400.0, 2 * 86_400.0, 86_400.0 + 60] {
            let standing = GraceStanding(expiresAt: now.addingTimeInterval(remaining))
            XCTAssertNil(
                EntitlementNotice(state: .ungated(standing), now: now),
                "\(remaining / 86_400) days out"
            )
        }
    }

    func testTheLastDayIsWarnedAboutAndArrivesPressing() throws {
        let standing = GraceStanding(expiresAt: now.addingTimeInterval(20 * 3600))
        let notice = try XCTUnwrap(EntitlementNotice(state: .ungated(standing), now: now))

        XCTAssertEqual(notice.headline, "Your last day before activation")
        XCTAssertEqual(notice.actionTitle, "Activate…")
        // There is no gentler step before this one, so it does not get one.
        XCTAssertTrue(notice.isPressing)
    }

    /// What the address actually buys, in the sentence that asks for it.
    func testTheNoticeSaysWhatTheEmailAdds() throws {
        let standing = GraceStanding(expiresAt: now.addingTimeInterval(3600))
        let notice = try XCTUnwrap(EntitlementNotice(state: .ungated(standing), now: now))

        XCTAssertTrue(notice.detail.contains("ten more days"))
        XCTAssertFalse(notice.detail.contains("whichever comes first"), "there is only one way for the window to end now")
    }

    /// Nothing has been spent, so there is nothing to count down.
    func testAnUntouchedRecordSaysNothing() {
        XCTAssertNil(EntitlementNotice(state: .ungated(.untouched), now: now))
    }

    // MARK: - The trial

    func testTheTrialWarnsInsideItsLastThreeDays() throws {
        let license = makeLicense(kind: .trial, expiresAt: now.addingTimeInterval(3 * 86_400))
        let notice = try XCTUnwrap(EntitlementNotice(state: .licensed(license), now: now))

        XCTAssertEqual(notice.headline, "The trial ends in 3 days")
        XCTAssertEqual(notice.actionTitle, "Open License settings")
        XCTAssertFalse(notice.isPressing)
    }

    func testTheLastDayIsSaidAsToday() throws {
        let license = makeLicense(kind: .trial, expiresAt: now.addingTimeInterval(6 * 3600))
        let notice = try XCTUnwrap(EntitlementNotice(state: .licensed(license), now: now))

        XCTAssertEqual(notice.headline, "The trial ends today")
        XCTAssertTrue(notice.isPressing)
    }

    /// Nothing here ever refuses anything — the notice is shown while the app
    /// is working, and the state it is drawn from still allows dictation.
    func testTheNoticeOnlyAppearsWhileDictationStillWorks() {
        let standing = GraceStanding(expiresAt: now.addingTimeInterval(600))
        XCTAssertTrue(EntitlementState.ungated(standing).allowsDictation)

        let license = makeLicense(kind: .trial, expiresAt: now.addingTimeInterval(3600))
        XCTAssertTrue(EntitlementState.licensed(license).allowsDictation)
    }

    private func makeLicense(kind: LicenseKind, expiresAt: Date?) -> License {
        License(
            id: "test",
            email: "someone@example.com",
            kind: kind,
            deviceID: "0123456789abcdef0123456789abcdef",
            issuedAt: now.addingTimeInterval(-86_400),
            expiresAt: expiresAt
        )
    }
}
