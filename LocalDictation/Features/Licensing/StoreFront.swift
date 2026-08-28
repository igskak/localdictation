import AppKit
import Foundation

/// The commercial offer, in one place, so changing a price is not a search.
///
/// The URLs are deliberately empty. `docs/PHASE_8_DECISIONS.md` D2 settles the
/// provider on availability rather than on economics — both candidates are
/// merchants of record and the fee difference is about a euro on a ninety-nine
/// euro sale — and neither account exists yet, so the paywall says the checkout
/// is not open rather than sending anyone to a page that is not there.
///
/// Filling these constants in is the whole of what turns buying on, on this
/// side. The other side is written: `Service/src/webhook.js` answers either
/// provider, and it is what turns a payment into a licence on an address.
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
