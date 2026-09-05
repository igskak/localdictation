import AppKit
import Foundation

/// The commercial offer, in one place, so changing a price is not a search.
///
/// `docs/PHASE_8_DECISIONS.md` D2, executed: Stripe, as merchant of record. The
/// two checkout URLs are its Payment Links, and filling them in is the whole of
/// what turned the Buy buttons on.
///
/// Which link is which was checked rather than assumed, because the failure is
/// silent and expensive: swapping them sells a lifetime licence for €49 and
/// nothing in the app could tell. `…ds401` shows €99 and a `Pay` button;
/// `…ds402` shows €49.00 / year and `Pay and subscribe`.
///
/// The other side is already written: `Service/src/webhook.js` turns the
/// resulting payment into a licence on the buyer's address, and the two links'
/// `plink_…` ids are what tell it which offer was bought — Stripe sends no line
/// items on a webhook, so the URL a buyer clicked is the only signal there is.
/// Those ids go in the service's configuration, not here.
///
/// Checkout always collects an address; there is no option for it and nothing
/// to switch on. That is what makes "the address is the licence" safe to build
/// on.
enum StoreFront {
    static let lifetimePrice = "€99"
    static let annualPrice = "€49"

    /// €99, once. `Pay` on the checkout page — a payment, not a subscription.
    static let lifetimeCheckout = URL(string: "https://buy.stripe.com/4gMeVd20c3xs58g8oads401")

    /// €49 a year, as a subscription. `Pay and subscribe` on the checkout page,
    /// which is why the offer copy says so: a recurring charge a buyer did not
    /// know they were agreeing to is the kind of surprise this product is
    /// supposed to be the opposite of.
    static let annualCheckout = URL(string: "https://buy.stripe.com/cNidR97kw6JEeIQ33Qds402")

    /// The product page. Read in one place that matters: a lifetime licence on
    /// a superseded major version is told to download the version it owns,
    /// which needs somewhere to download it from.
    static let websiteURL = URL(string: "https://witnessmac.com")

    /// The contract, and the withdrawal instruction.
    ///
    /// These are not decoration next to the price. A buyer is about to be sent
    /// to a page that takes their money, and the two declarations the checkout
    /// consent asks for — deliver now, and I lose the right to withdraw —
    /// mean nothing if the documents they point at are unreachable from the
    /// screen where they are made. `CheckoutConsent` links both.
    static let termsURL = URL(string: "https://witnessmac.com/agb")
    static let withdrawalURL = URL(string: "https://witnessmac.com/widerruf")

    static var isOpen: Bool { lifetimeCheckout != nil || annualCheckout != nil }

    static func checkoutURL(for offer: TelemetryEvent.Offer) -> URL? {
        switch offer {
        case .lifetime: lifetimeCheckout
        case .annual: annualCheckout
        }
    }

    static func price(for offer: TelemetryEvent.Offer) -> String {
        switch offer {
        case .lifetime: lifetimePrice
        case .annual: annualPrice
        }
    }

    /// How a URL reaches the browser.
    ///
    /// A `var` because `AGENTS.md` keeps system APIs behind an adapter, and
    /// because the alternative is a test suite that launches a real Stripe
    /// checkout in a real browser every time it runs the consent rule.
    @MainActor
    static var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Hands the URL to the browser. The app opens no window of its own for
    /// payment and never sees a card number — the payment provider is the
    /// merchant of record, and its checkout page is where the transaction and
    /// the VAT both live.
    @MainActor
    static func open(_ url: URL) {
        opener(url)
    }
}
