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

    func testTheCountdownStartsWithTheFirstDictation() throws {
        let standing = GraceStanding(dictationsRemaining: 4, expiresAt: now.addingTimeInterval(20 * 3600))
        let notice = try XCTUnwrap(EntitlementNotice(state: .ungated(standing), now: now))

        XCTAssertEqual(notice.headline, "4 dictations left before activation")
        XCTAssertEqual(notice.actionTitle, "Activate…")
        XCTAssertFalse(notice.isPressing)
    }

    /// Both numbers, because the window closes on whichever runs out first and
    /// a countdown that shows only the slower one surprises people.
    func testTheDeadlineIsNamedAlongsideTheCount() throws {
        let standing = GraceStanding(dictationsRemaining: 2, expiresAt: now.addingTimeInterval(3600))
        let notice = try XCTUnwrap(EntitlementNotice(state: .ungated(standing), now: now))

        XCTAssertTrue(notice.detail.contains("whichever comes first"))
        XCTAssertTrue(notice.detail.contains("fourteen days"))
    }

    func testTheLastPressIsSaidInTheSingularAndPressed() throws {
        let standing = GraceStanding(dictationsRemaining: 1, expiresAt: now.addingTimeInterval(3600))
        let notice = try XCTUnwrap(EntitlementNotice(state: .ungated(standing), now: now))

        XCTAssertEqual(notice.headline, "One dictation left before activation")
        XCTAssertTrue(notice.isPressing)
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
        let standing = GraceStanding(dictationsRemaining: 1, expiresAt: now.addingTimeInterval(600))
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
