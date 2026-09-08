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

    // MARK: - What actually goes on a wire

    /// The gate, on the event rather than on the call site. A transport that
    /// decides per caller is a transport that sends the eighth event the day
    /// somebody adds a call in the wrong place.
    func testOnlyTheThreeFunnelEventsAreTransmitted() {
        XCTAssertTrue(TelemetryEvent.trialStarted.isTransmitted)
        XCTAssertTrue(TelemetryEvent.activationRequested.isTransmitted)
        XCTAssertTrue(TelemetryEvent.paywallShown(.trialExpired).isTransmitted)

        XCTAssertFalse(TelemetryEvent.installed.isTransmitted)
        XCTAssertFalse(TelemetryEvent.activationSucceeded.isTransmitted)
        XCTAssertFalse(TelemetryEvent.licenseAccepted(.lifetime).isTransmitted)
        XCTAssertFalse(TelemetryEvent.checkoutOpened(.annual).isTransmitted)
        XCTAssertFalse(TelemetryEvent.entitlementLapsed(.trial).isTransmitted)
    }

    /// The body, byte for byte, without a server. `.sortedKeys` is what makes
    /// this assertable and what makes `docs/PRIVACY.md`'s example true.
    func testTheRequestCarriesTheFiveDisclosedFieldsAndNothingElse() throws {
        let envelope = service.envelope(for: .paywallShown(.trialExpired))
        let endpoint = try XCTUnwrap(URL(string: "https://api.example.com/v1/events"))
        let request = try XCTUnwrap(HTTPProductTelemetryService.request(to: endpoint, envelope: envelope))

        XCTAssertEqual(request.httpMethod, "POST")
        // A default user agent would put an app build and an OS build on the
        // wire without either appearing in the privacy policy.
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Witness")

        let body = try XCTUnwrap(request.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(fields.keys.sorted(), TelemetryEventBody.allowedFields)
        XCTAssertEqual(fields["event"], "paywall_shown")
        XCTAssertEqual(fields["qualifier"], "trialExpired")
        XCTAssertEqual(fields["install_id"], "install-id")
        XCTAssertEqual(fields["app_version"], "1.0")
        XCTAssertEqual(fields["system_version"], "14.4")
    }

    /// An event with no qualifier leaves the field out rather than sending
    /// `null`, which is what the documented example shows.
    func testAnEventWithoutAQualifierOmitsTheField() throws {
        let envelope = service.envelope(for: .trialStarted)
        let endpoint = try XCTUnwrap(URL(string: "https://api.example.com/v1/events"))
        let request = try XCTUnwrap(HTTPProductTelemetryService.request(to: endpoint, envelope: envelope))

        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(fields.keys.sorted(), ["app_version", "event", "install_id", "system_version"])
    }

    /// The switch in Settings → Privacy, at the only place that matters.
    func testTheConsentSwitchIsWhatDecidesWhetherAnythingLeaves() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.example.com/v1/events"))
        let consent = TelemetryConsent()
        let sent = Sent()
        let telemetry = HTTPProductTelemetryService(
            endpoint: endpoint,
            local: service,
            consent: consent,
            transmit: { sent.append($0) }
        )

        telemetry.send(.trialStarted)
        XCTAssertEqual(sent.count, 1, "the default is on, and the first-run screen says so")

        consent.isAllowed = false
        telemetry.send(.trialStarted)
        telemetry.send(.activationRequested)
        telemetry.send(.paywallShown(.trialExpired))
        XCTAssertEqual(sent.count, 1, "the switch was off and three events still left")

        consent.isAllowed = true
        telemetry.send(.activationRequested)
        XCTAssertEqual(sent.count, 2, "the switch takes effect on the next event, not the next launch")
    }

    /// The other seven never reach the transport, switch or no switch.
    func testTheSevenLocalEventsNeverReachTheWire() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.example.com/v1/events"))
        let sent = Sent()
        let telemetry = HTTPProductTelemetryService(
            endpoint: endpoint,
            local: service,
            consent: TelemetryConsent(),
            transmit: { sent.append($0) }
        )

        telemetry.send(.installed)
        telemetry.send(.activationSucceeded)
        telemetry.send(.activationFailed(.unreachable))
        telemetry.send(.licenseAccepted(.lifetime))
        telemetry.send(.licenseRejected(.wrongDevice))
        telemetry.send(.checkoutOpened(.lifetime))
        telemetry.send(.entitlementLapsed(.annual))

        XCTAssertEqual(sent.count, 0)
    }

    /// A plain-HTTP endpoint makes the transport report itself unconfigured
    /// rather than sending in the clear — the rule `HTTPActivationBackend` has,
    /// and there is no setting that relaxes it in any build.
    func testAPlainHTTPEndpointSendsNothing() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://api.example.com/v1/events"))
        let sent = Sent()
        let telemetry = HTTPProductTelemetryService(
            endpoint: endpoint,
            local: service,
            consent: TelemetryConsent(),
            transmit: { sent.append($0) }
        )

        XCTAssertFalse(telemetry.isConfigured)
        telemetry.send(.trialStarted)
        XCTAssertEqual(sent.count, 0)
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        var count: Int { lock.withLock { requests.count } }
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
