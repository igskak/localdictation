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

// MARK: - What may leave, and what may not

extension TelemetryEvent {
    /// The three events that answer the question this transport exists for.
    ///
    /// `docs/PHASE_8_DECISIONS.md` D7 shipped the first release transmitting
    /// nothing, and the reason to reverse it is one measurement: how many
    /// people reach the wall at the fifth dictation and how many get past it.
    /// That is `trial_started` as the denominator, `paywall_shown` as the
    /// refusal, and `activation_requested` as the way out.
    ///
    /// The other seven stay local. Not because they are more sensitive — every
    /// event in this type carries the same five fields — but because a list
    /// that grows to "all of them" is a list nobody reads, and this one is
    /// printed in the privacy policy where a person can hold it against the
    /// app. `activation_succeeded` and `license_accepted` are also already
    /// known to the service from the calls that cause them, so sending them
    /// again would buy nothing and lengthen the list.
    static let transmitted: Set<String> = ["trial_started", "activation_requested", "paywall_shown"]

    var isTransmitted: Bool { Self.transmitted.contains(name) }
}

/// The wire body, so the field list is a type rather than a habit.
///
/// The same arrangement `ActivationRequestBody` has: five fields, a test that
/// fails when a sixth appears, and `docs/PRIVACY.md` naming every one of them.
/// `qualifier` is absent rather than null when there is none, which is why it
/// is the only optional.
struct TelemetryEventBody: Codable, Sendable, Equatable {
    let appVersion: String
    let event: String
    let installID: String
    let qualifier: String?
    let systemVersion: String

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case event
        case installID = "install_id"
        case qualifier
        case systemVersion = "system_version"
    }

    static let allowedFields = ["app_version", "event", "install_id", "qualifier", "system_version"]

    init(_ envelope: TelemetryEnvelope) {
        appVersion = envelope.appVersion
        event = envelope.event
        installID = envelope.installID
        qualifier = envelope.qualifier
        systemVersion = envelope.systemVersion
    }
}

/// Whether the user has left product events on.
///
/// A box rather than a value because the answer arrives after the object that
/// needs it: `EntitlementService` is built in the composition root and the
/// preferences file is read by `DictationCoordinator` a moment later. Reading
/// through this means the toggle in Settings takes effect on the next event
/// rather than on the next launch, and there is no ordering to get wrong.
///
/// It starts `true`. `docs/PRIVACY.md` says so, the first-run screen says so,
/// and Settings → Privacy is where it is turned off.
final class TelemetryConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool

    init(allowed: Bool = true) {
        self.allowed = allowed
    }

    var isAllowed: Bool {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue } }
    }
}

/// The address product events go to, and the switch that turns them on.
///
/// The same shape as `ActivationEndpoint`, for the same reason: one constant,
/// compiled in, on a domain the product owns. A build with no endpoint sends
/// nothing and says so in the log — which is exactly what every build before
/// this one did.
enum TelemetryEndpoint {
    static let production = URL(string: "https://api.witnessmac.com/v1/events")

    static func service(installID: String, consent: TelemetryConsent) -> any ProductTelemetryService {
        let local = LocalOnlyTelemetryService(
            appVersion: AppVersion.short,
            systemVersion: AppVersion.systemShort,
            installID: installID
        )
        guard let production else { return local }
        return HTTPProductTelemetryService(endpoint: production, local: local, consent: consent)
    }
}

/// Sends the three transmitted events, once, and forgets about them.
///
/// Everything about this is deliberately smaller than it could be:
///
/// - **One attempt, no queue.** A retry queue is a fourth file this app writes
///   to disk, and `docs/PRIVACY.md` enumerates three. An event lost to a closed
///   laptop is a missing row in a funnel, which is a rounding error; a new file
///   holding a record of what the user did is a different product.
/// - **No answer is read.** The service replies `202` and the app does not care
///   whether it did. Nothing here can fail in a way the user should be told
///   about, so nothing here has a way to tell them.
/// - **It never blocks a press.** `send` returns immediately; the request runs
///   on a detached task. A licensing decision has already been made by the time
///   this is called, and a slow network must not be able to reach it.
struct HTTPProductTelemetryService: ProductTelemetryService {
    private let endpoint: URL
    private let local: LocalOnlyTelemetryService
    private let consent: TelemetryConsent
    /// Injected so a test can assert what would go on the wire without one.
    private let transmit: @Sendable (URLRequest) -> Void

    init(
        endpoint: URL,
        local: LocalOnlyTelemetryService,
        consent: TelemetryConsent,
        transmit: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.local = local
        self.consent = consent
        self.transmit = transmit ?? Self.fireAndForget
    }

    /// `https` or nothing, the same rule `HTTPActivationBackend` has. There is
    /// no setting that relaxes it in any build.
    var isConfigured: Bool { endpoint.scheme?.lowercased() == "https" }

    func send(_ event: TelemetryEvent) {
        let envelope = local.envelope(for: event)

        guard isConfigured, event.isTransmitted, consent.isAllowed else {
            local.send(event)
            return
        }

        Log.licensing.debug("Product event \(envelope.event, privacy: .public) \(envelope.qualifier ?? "-", privacy: .public) (sent)")

        guard let request = Self.request(to: endpoint, envelope: envelope) else { return }
        transmit(request)
    }

    /// The request, alone, so a test can hold it up against the privacy policy
    /// without a server. `.sortedKeys` because the body in the document is
    /// compared to this one byte for byte.
    static func request(to endpoint: URL, envelope: TelemetryEnvelope) -> URLRequest? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(TelemetryEventBody(envelope)) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No `Accept`: there is nothing here that reads a reply. The user agent
        // carries no version for the reason it carries none in
        // `HTTPActivationBackend` — except that here the version is in the body,
        // disclosed, rather than added to the request by a default nobody wrote.
        request.setValue("Witness", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    /// An ephemeral session per event rather than one held for the life of the
    /// app: there are at most a handful of these in a fortnight, and a session
    /// kept alive is a connection to a server this product tells people it
    /// mostly does not talk to.
    @Sendable
    private static func fireAndForget(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15

        let session = URLSession(configuration: configuration)
        Task.detached(priority: .background) {
            _ = try? await session.data(for: request)
            session.finishTasksAndInvalidate()
        }
    }
}
