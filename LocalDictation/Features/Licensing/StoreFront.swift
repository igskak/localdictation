import AppKit
import Foundation

/// The commercial offer, in one place, so changing a price is not a search.
///
/// The URLs are deliberately empty. `docs/PRODUCT_SCOPE.md` makes checkout
/// conditional on Stripe Managed Payments being available and this product
/// being eligible, and neither has been confirmed in the project account — so
/// the paywall says the checkout is not open yet rather than sending anyone to
/// a page that does not exist. Filling these two constants in is the whole of
/// what turns buying on.
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
    /// payment and never sees a card number — Stripe is the merchant of record
    /// and its checkout page is where the transaction lives.
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
