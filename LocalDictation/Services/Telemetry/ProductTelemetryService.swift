import Foundation

/// The complete list of events this product may ever send.
///
/// It is an enum and not a string for one reason: a string parameter is a hole
/// a transcript can fall through. Every case below is a fact about the funnel —
/// something happened in the licensing flow — and none of them can carry a
/// word the user said, a term from their dictionary, or the name of an
/// application they dictated into. Adding a case means editing this file, and
/// editing this file means editing the privacy policy, which is the point.
enum TelemetryEvent: Sendable, Equatable {
    case installed
    case trialStarted
    case activationRequested
    case activationSucceeded
    case activationFailed(ActivationFailureReason)
    case licenseAccepted(LicenseKind)
    case licenseRejected(LicenseRejectionReason)
    case paywallShown(PaywallTrigger)
    case checkoutOpened(Offer)
    case entitlementLapsed(LicenseKind)

    enum ActivationFailureReason: String, Sendable, Equatable {
        case notConfigured
        case invalidEmail
        case unreachable
        case rejected
        case deviceLimitReached
    }

    enum LicenseRejectionReason: String, Sendable, Equatable {
        case malformed
        case unsupportedVersion
        case noAuthority
        case badSignature
        case wrongDevice
        case inconsistentDates
    }

    enum PaywallTrigger: String, Sendable, Equatable {
        case activationRequired
        case trialExpired
        case licenseExpired
        /// A lifetime license on a major version it did not buy.
        case updateRequired
    }

    enum Offer: String, Sendable, Equatable {
        case lifetime
        case annual
    }

    /// The wire name. Stable, because a renamed event is a broken funnel.
    var name: String {
        switch self {
        case .installed: "installed"
        case .trialStarted: "trial_started"
        case .activationRequested: "activation_requested"
        case .activationSucceeded: "activation_succeeded"
        case .activationFailed: "activation_failed"
        case .licenseAccepted: "license_accepted"
        case .licenseRejected: "license_rejected"
        case .paywallShown: "paywall_shown"
        case .checkoutOpened: "checkout_opened"
        case .entitlementLapsed: "entitlement_lapsed"
        }
    }

    /// The one optional field, always drawn from a fixed set of strings above.
    var qualifier: String? {
        switch self {
        case let .activationFailed(reason): reason.rawValue
        case let .licenseRejected(reason): reason.rawValue
        case let .licenseAccepted(kind): kind.rawValue
        case let .entitlementLapsed(kind): kind.rawValue
        case let .paywallShown(trigger): trigger.rawValue
        case let .checkoutOpened(offer): offer.rawValue
        case .installed, .trialStarted, .activationRequested, .activationSucceeded: nil
        }
    }
}

/// Everything that travels with an event.
///
/// Four fields, and the test that asserts there are four is the enforcement.
/// `installID` is a random value created at install; it is not derived from the
/// Mac, so it cannot be matched to the device hash a license carries or to
/// anything outside this product.
struct TelemetryEnvelope: Sendable, Equatable {
    let event: String
    let qualifier: String?
    let appVersion: String
    /// Major and minor only — "14.4", never the build. A point release is not
    /// a funnel question, and a rare OS build is an identifier.
    let systemVersion: String
    let installID: String

    static let allowedFields = ["event", "qualifier", "app_version", "system_version", "install_id"]

    var payload: [String: String] {
        var fields = [
            "event": event,
            "app_version": appVersion,
            "system_version": systemVersion,
            "install_id": installID
        ]
        if let qualifier { fields["qualifier"] = qualifier }
        return fields
    }
}

protocol ProductTelemetryService: Sendable {
    func send(_ event: TelemetryEvent)
}

/// What ships today.
///
/// It builds the envelope and writes it to the local log instead of sending it.
/// The events are real, the shapes are real, and nothing leaves the Mac — so
/// the day a collector exists, what turns on is a transport and not a design.
struct LocalOnlyTelemetryService: ProductTelemetryService {
    let appVersion: String
    let systemVersion: String
    let installID: String

    init(appVersion: String, systemVersion: String, installID: String) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.installID = installID
    }

    func envelope(for event: TelemetryEvent) -> TelemetryEnvelope {
        TelemetryEnvelope(
            event: event.name,
            qualifier: event.qualifier,
            appVersion: appVersion,
            systemVersion: systemVersion,
            installID: installID
        )
    }

    func send(_ event: TelemetryEvent) {
        let envelope = envelope(for: event)
        Log.licensing.debug(
            "Product event \(envelope.event, privacy: .public) \(envelope.qualifier ?? "-", privacy: .public) (not transmitted)"
        )
    }
}
