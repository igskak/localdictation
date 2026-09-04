import XCTest
@testable import Witness

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

    // MARK: - Fetching a license that was bought elsewhere

    /// A paid key names a Mac, and a browser does not know which Mac. So the
    /// address form has to stay reachable everywhere a user might already own
    /// something this machine has no key for — without ever becoming the thing
    /// an expired trial leads with.
    func testAnExpiredTrialCanStillFetchAKeyThatWasBought() {
        let presentation = LicensePresentation(state: .locked(.expired(.trial, at: now)), now: now)

        XCTAssertTrue(presentation.offersKeyRetrieval)
        XCTAssertFalse(presentation.showsActivation, "the offer still leads")
        XCTAssertEqual(presentation.activationButtonTitle, "Send my key")
        XCTAssertTrue(presentation.activationHint.contains("bought with"))
    }

    func testAnActivatedTrialCanFetchTheLicenseThatReplacesIt() {
        let presentation = LicensePresentation(state: .licensed(makeLicense(kind: .trial)), now: now)

        XCTAssertTrue(presentation.offersKeyRetrieval)
    }

    func testAnExpiredAnnualLicenseCanFetchItsRenewal() {
        let presentation = LicensePresentation(state: .locked(.expired(.annual, at: now)), now: now)

        XCTAssertTrue(presentation.offersKeyRetrieval)
    }

    /// Two forms doing the same thing, one above the other. The states that
    /// already lead with the form have nothing to retrieve.
    func testTheFormIsNeverOfferedTwice() {
        for state in [EntitlementState.ungated(.untouched), .locked(.activationRequired)] {
            let presentation = LicensePresentation(state: state, now: now)
            XCTAssertTrue(presentation.showsActivation)
            XCTAssertFalse(presentation.offersKeyRetrieval)
            XCTAssertEqual(presentation.activationButtonTitle, "Send me a key")
        }
    }

    func testALifetimeLicenseHasNothingLeftToFetch() {
        let presentation = LicensePresentation(state: .licensed(makeLicense(kind: .lifetime)), now: now)

        XCTAssertFalse(presentation.offersKeyRetrieval)
        XCTAssertFalse(presentation.showsActivation)
    }

    private func makeLicense(kind: LicenseKind) -> License {
        License(
            id: "lic",
            email: "owner@example.com",
            kind: kind,
            deviceID: "device",
            issuedAt: now,
            expiresAt: kind == .lifetime ? nil : now.addingTimeInterval(5 * 86_400)
        )
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
    /// From a live purchase: the app told a customer holding a year that "the
    /// trial runs for fourteen days". The sentence was chosen from the form's
    /// label before the call instead of from the licence that came back.
    func testTheSuccessSentenceDescribesWhatArrivedAndNotWhatWasAsked() {
        XCTAssertEqual(
            LicensePresentation.activationSucceeded(.annual),
            "Your annual license is on this Mac now."
        )
        XCTAssertTrue(LicensePresentation.activationSucceeded(.lifetime).contains("lifetime"))
        XCTAssertTrue(LicensePresentation.activationSucceeded(.trial).contains("fourteen days"))

        for kind in [LicenseKind.annual, .lifetime] {
            XCTAssertFalse(
                LicensePresentation.activationSucceeded(kind).contains("trial"),
                "a paid licence is never described as a trial"
            )
            XCTAssertFalse(LicensePresentation.activationSucceeded(kind).contains("fourteen"))
        }

        // A key that verified but left no licence to read is still an
        // acceptance, and says only that.
        XCTAssertEqual(
            LicensePresentation.activationSucceeded(nil),
            "The key for this Mac was accepted."
        )
    }

}
