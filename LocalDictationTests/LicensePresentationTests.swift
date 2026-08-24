import XCTest
@testable import LocalDictation

/// In the locked states this copy is the entire product, so it is tested like
/// any other output.
final class LicensePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAFreshInstallIsToldWhatIsFreeAndNothingElse() {
        let presentation = LicensePresentation(state: .ungated(.untouched), now: now)

        XCTAssertTrue(presentation.showsActivation)
        XCTAssertFalse(presentation.showsOffers, "an app nobody has finished trying is not a sales page")
        XCTAssertTrue(presentation.detail.contains("\(EntitlementPolicy.ungatedDictations)"))
    }

    func testTheCountdownNamesBothWaysTheWindowCanClose() {
        let standing = GraceStanding(dictationsRemaining: 2, expiresAt: now.addingTimeInterval(3600))
        let presentation = LicensePresentation(state: .ungated(standing), now: now)

        XCTAssertTrue(presentation.detail.contains("2 dictations"))
        XCTAssertTrue(presentation.detail.contains("whichever comes first"))
    }

    func testALockedTrialLeadsWithTheOfferAndNotWithTheForm() {
        let presentation = LicensePresentation(state: .locked(.expired(.trial, at: now)), now: now)

        XCTAssertTrue(presentation.showsOffers)
        XCTAssertFalse(presentation.showsActivation, "asking again for an email they already gave is the wrong door")
    }

    func testActivationRequiredLeadsWithTheFormAndNotWithTheOffer() {
        let presentation = LicensePresentation(state: .locked(.activationRequired), now: now)

        XCTAssertTrue(presentation.showsActivation)
        XCTAssertFalse(presentation.showsOffers, "the trial has not been used yet — selling here would be selling too early")
    }

    /// A lifetime license is the one state with nothing left to say.
    func testALifetimeLicenseIsNeverSoldToAgain() {
        let license = License(
            id: "lic",
            email: "owner@example.com",
            kind: .lifetime,
            deviceID: "device",
            issuedAt: now,
            expiresAt: nil
        )

        let presentation = LicensePresentation(state: .licensed(license), now: now)

        XCTAssertFalse(presentation.showsOffers)
        XCTAssertFalse(presentation.showsActivation)
        XCTAssertTrue(presentation.detail.contains("owner@example.com"))
    }

    func testAnActivatedTrialCountsDownInDays() {
        let license = License(
            id: "lic",
            email: "owner@example.com",
            kind: .trial,
            deviceID: "device",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3 * 86_400)
        )

        let presentation = LicensePresentation(state: .licensed(license), now: now)

        XCTAssertTrue(presentation.detail.contains("3 days"))
        XCTAssertTrue(presentation.showsOffers)
    }

    /// The status line the menu bar shows, which is the only licensing text
    /// most users will ever read.
    func testTheMenuBarSaysWhichDoorIsInFront() {
        let activation = StatusPresentation(state: .locked(.activationRequired), binding: .optionSpace)
        let expired = StatusPresentation(state: .locked(.expired(.trial, at: now)), binding: .optionSpace)

        XCTAssertTrue(activation.showsLicenseAction)
        XCTAssertTrue(expired.showsLicenseAction)
        XCTAssertEqual(activation.tint, .warning)
        XCTAssertNotEqual(activation.title, expired.title)
        XCTAssertFalse(StatusPresentation(state: .ready, binding: .optionSpace).showsLicenseAction)
    }
}
