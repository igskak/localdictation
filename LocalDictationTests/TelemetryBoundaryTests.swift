import XCTest
@testable import Witness

/// The privacy boundary as a test rather than a promise.
///
/// `docs/PRODUCT_SCOPE.md` allows a short list of non-content product events and
/// forbids everything else. What makes that checkable is that an event is an
/// enum with no free-form string in it: there is no parameter a transcript
/// could be passed to, so the assertion below is about the shape of the type
/// and not about the discipline of whoever adds the next call site.
final class TelemetryBoundaryTests: XCTestCase {
    private let service = LocalOnlyTelemetryService(
        appVersion: "1.0",
        systemVersion: "14.4",
        installID: "install-id"
    )

    func testAnEventCarriesFiveFieldsAtMost() {
        let envelope = service.envelope(for: .checkoutOpened(.lifetime))

        XCTAssertEqual(Set(envelope.payload.keys).subtracting(TelemetryEnvelope.allowedFields), [])
        XCTAssertEqual(envelope.payload["event"], "checkout_opened")
        XCTAssertEqual(envelope.payload["qualifier"], "lifetime")
    }

    /// Every qualifier is drawn from a fixed set, so no event can smuggle a
    /// word out in the one optional field.
    func testEveryQualifierComesFromAFixedSet() {
        let allowed: Set<String> = [
            "notConfigured", "invalidEmail", "unreachable", "rejected", "deviceLimitReached",
            "malformed", "unsupportedVersion", "noAuthority", "badSignature", "wrongDevice",
            "inconsistentDates", "trial", "annual", "lifetime",
            "activationRequired", "trialExpired", "licenseExpired"
        ]

        let events: [TelemetryEvent] = [
            .installed,
            .trialStarted,
            .activationRequested,
            .activationSucceeded,
            .activationFailed(.unreachable),
            .licenseAccepted(.annual),
            .licenseRejected(.badSignature),
            .paywallShown(.trialExpired),
            .checkoutOpened(.annual),
            .entitlementLapsed(.trial)
        ]

        for event in events {
            guard let qualifier = event.qualifier else { continue }
            XCTAssertTrue(allowed.contains(qualifier), "\(event.name) carried an unlisted qualifier")
        }
    }

    /// The system version is coarse on purpose: a rare build number is an
    /// identifier, and a point release is not a funnel question.
    func testTheSystemVersionIsMajorAndMinorOnly() {
        XCTAssertEqual(AppVersion.systemShort.split(separator: ".").count, 2)
    }

    /// The install identifier is random and is not the device hash, so what a
    /// license carries and what an event carries cannot be joined.
    func testTheInstallIdentifierIsNotDerivedFromTheMac() {
        let first = UsageRecord.new(at: Date()).installID
        let second = UsageRecord.new(at: Date()).installID

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, HardwareDeviceIdentity(platformUUID: "any").deviceID)
    }
}
