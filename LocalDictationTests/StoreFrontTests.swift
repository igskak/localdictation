import XCTest
@testable import Witness

/// The commercial surface, held to the few things about it that can be wrong
/// silently.
///
/// Every other test in the licensing suite is about a refusal a user can read.
/// These are about the opposite: a mistake here produces a working, plausible
/// checkout that charges the wrong amount, and nothing in the app is in a
/// position to notice. So the offers are pinned to distinct pages, the pages
/// are pinned to `https`, and the prices the app prints are pinned to the ones
/// the pages actually charge.
final class StoreFrontTests: XCTestCase {
    /// `docs/PHASE_8_DECISIONS.md` D2 is executed, so the buttons are live. The
    /// paywall's "checkout is not open yet" sentence is gone with it, and this
    /// is what says so.
    func testCheckoutIsOpen() {
        XCTAssertTrue(StoreFront.isOpen)
        XCTAssertNotNil(StoreFront.lifetimeCheckout)
        XCTAssertNotNil(StoreFront.annualCheckout)
    }

    /// The expensive mistake. Both offers pointing at one link sells a lifetime
    /// licence for €49, or an annual subscription for €99, and every screen in
    /// the app would still read correctly.
    func testTheTwoOffersGoToDifferentPages() throws {
        let lifetime = try XCTUnwrap(StoreFront.checkoutURL(for: .lifetime))
        let annual = try XCTUnwrap(StoreFront.checkoutURL(for: .annual))
        XCTAssertNotEqual(lifetime, annual)
    }

    /// Verified against the live pages rather than assumed from the URLs, which
    /// are random strings: `…ds401` shows €99.00 with a `Pay` button, `…ds402`
    /// shows €49.00 / year with `Pay and subscribe`.
    func testEachOfferGoesToThePageThatChargesIt() throws {
        XCTAssertEqual(StoreFront.price(for: .lifetime), "€99")
        XCTAssertEqual(StoreFront.price(for: .annual), "€49")

        XCTAssertTrue(try XCTUnwrap(StoreFront.checkoutURL(for: .lifetime)).absoluteString.hasSuffix("ds401"))
        XCTAssertTrue(try XCTUnwrap(StoreFront.checkoutURL(for: .annual)).absoluteString.hasSuffix("ds402"))
    }

    /// A card number is about to be typed into whatever these open. The app
    /// hands them to the browser without looking at them, so the one property
    /// it can check is the scheme.
    func testEveryPageTheAppOpensIsHTTPS() throws {
        let pages = [
            StoreFront.lifetimeCheckout,
            StoreFront.annualCheckout,
            StoreFront.websiteURL,
            StoreFront.termsURL,
            StoreFront.withdrawalURL,
        ]
        for url in pages.compactMap({ $0 }) {
            XCTAssertEqual(url.scheme, "https", "\(url) is not https")
        }
    }

    /// The two documents the checkout declaration points at.
    ///
    /// They are not decoration. A buyer ticking "deliver now, and I give up my
    /// right of withdrawal" is making a declaration about a contract, and a
    /// declaration about a contract nobody can open from that screen is the
    /// part a lawyer asks about first. Both are published pages, so a `nil`
    /// here is a link the app forgot rather than a page that does not exist.
    func testTheDeclarationCanReachTheDocumentsItIsAbout() throws {
        let terms = try XCTUnwrap(StoreFront.termsURL)
        let withdrawal = try XCTUnwrap(StoreFront.withdrawalURL)

        XCTAssertNotEqual(terms, withdrawal)
        XCTAssertEqual(terms.host, "witnessmac.com")
        XCTAssertEqual(withdrawal.host, "witnessmac.com")
        XCTAssertNotNil(StoreFront.websiteURL, "the site is live; a lifetime licence on an old major version is sent here")
    }

    /// The paywall leads with the offers only where buying is the thing to do.
    /// With the buttons live, a trial that has run out has somewhere to go.
    func testAnExpiredTrialIsOfferedSomethingToBuy() {
        let presentation = LicensePresentation(state: .locked(.expired(.trial, at: Date())))
        XCTAssertTrue(presentation.showsOffers)
        XCTAssertTrue(presentation.offersKeyRetrieval, "and a way back for somebody who has already paid")
    }
}
