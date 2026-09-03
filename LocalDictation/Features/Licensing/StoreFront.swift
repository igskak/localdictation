import AppKit
import Foundation

/// The commercial offer, in one place, so changing a price is not a search.
///
/// The URLs are deliberately empty, and they are the last code change this
/// phase is waiting on. `docs/PHASE_8_DECISIONS.md` D2 is settled — Stripe, as
/// merchant of record — so what goes here is concrete:
///
/// - `lifetimeCheckout` and `annualCheckout`: the two Stripe **Payment Link**
///   URLs, `https://buy.stripe.com/…`. Collect the customer's email on both;
///   the address *is* the licence, and a checkout that collects none produces
///   an event the service can do nothing with.
/// - `websiteURL`: the product page, once there is one.
///
/// Until then the paywall says the checkout is not open rather than sending
/// anyone to a page that is not there. The other side is already written:
/// `Service/src/webhook.js` turns the resulting payment into a licence on that
/// address, and the same two links' `plink_…` ids are what tell it which of the
/// two offers was bought — Stripe sends no line items on a webhook.
enum StoreFront {
    static let lifetimePrice = "€99"
    static let annualPrice = "€49"

    static let lifetimeCheckout: URL? = nil
    static let annualCheckout: URL? = nil
    static let websiteURL: URL? = nil

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

    /// Hands the URL to the browser. The app opens no window of its own for
    /// payment and never sees a card number — the payment provider is the
    /// merchant of record, and its checkout page is where the transaction and
    /// the VAT both live.
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
