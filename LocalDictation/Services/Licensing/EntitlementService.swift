import Foundation

/// Holds the licensing state of this Mac, and is the only thing that may
/// change it.
///
/// It is not an `ObservableObject`: `DictationCoordinator` owns the published
/// surface the way it does for the dictionary, so the views keep one source of
/// truth to observe and this type stays testable without SwiftUI.
///
/// Everything it decides is a pure function elsewhere — `EntitlementPolicy` for
/// the dates and counts, `LicenseKey` for the signature. What lives here is the
/// order those are called in, and the rule that the answer is recomputed rather
/// than remembered.
@MainActor
final class EntitlementService {
    private(set) var state: EntitlementState = .ungated(.untouched)
    private(set) var storeErrorDescription: String?

    /// Called whenever `state` changes, so the coordinator can republish it.
    var onChange: (@MainActor (EntitlementState) -> Void)?

    let deviceID: String
    private let store: any EntitlementStore
    private let authority: LicenseAuthority
    private let backend: any ActivationBackend
    private let telemetry: any ProductTelemetryService
    private let clock: @Sendable () -> Date

    private var record: UsageRecord
    /// The verified license, or `nil`. Never written from anywhere but
    /// `reevaluate`, which re-derives it from the stored token.
    private(set) var license: License?

    init(
        store: any EntitlementStore,
        authority: LicenseAuthority = .production,
        deviceIdentity: any DeviceIdentityProviding = HardwareDeviceIdentity(),
        backend: any ActivationBackend = UnconfiguredActivationBackend(),
        telemetry: (any ProductTelemetryService)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.authority = authority
        self.deviceID = deviceIdentity.deviceID
        self.backend = backend
        self.clock = clock

        let loaded = (try? store.load()) ?? nil
        let isFirstRun = loaded == nil
        self.record = loaded ?? UsageRecord.new(at: clock())
        self.telemetry = telemetry ?? LocalOnlyTelemetryService(
            appVersion: AppVersion.short,
            systemVersion: AppVersion.systemShort,
            installID: record.installID
        )

        if isFirstRun {
            persist()
            self.telemetry.send(.installed)
        }
        reevaluate()
    }

    var canRequestActivation: Bool { backend.isConfigured }
    var authorityIsConfigured: Bool { authority.isConfigured }
    var recordLocationDescription: String { store.locationDescription }

    // MARK: - Reading

    /// Recomputes the state from the record, the stored token, and the clock.
    ///
    /// Called on launch, when the app comes forward, and after anything that
    /// could change the answer. A license that expires while the app is open
    /// has to be noticed without a relaunch, and the cheapest way to be sure of
    /// that is never to cache the verdict.
    func refresh() {
        reevaluate()
    }

    private func reevaluate() {
        let now = clock()
        record.observe(now: now)

        var verified: License?
        if let token = record.licenseToken {
            verified = try? LicenseKey.verify(token, authority: authority, deviceID: deviceID)
            if verified == nil {
                // A token that no longer verifies is dropped rather than kept:
                // it can only be a key for another Mac, a key from another
                // build, or an edited file, and holding it would mean showing
                // the user a license they do not have.
                Log.licensing.notice("Stored license token no longer verifies; discarding it")
                record.licenseToken = nil
                persist()
            }
        }

        let previous = state
        license = verified
        state = EntitlementPolicy.evaluate(record: record, license: verified, now: now)

        guard state != previous else { return }
        let label = state.logLabel
        Log.licensing.info("Entitlement \(label, privacy: .public)")
        if case let .locked(lock) = state {
            // Deliberately not `paywallShown` here. Becoming locked is a fact
            // about this Mac; being shown a price is a fact about a person, and
            // conflating them reports a paywall to everyone whose trial quietly
            // ran out in the background. `notePaywallShown` is sent from the
            // window that draws the offers.
            if case let .expired(kind, _) = lock { telemetry.send(.entitlementLapsed(kind)) }
        }
        onChange?(state)
    }

    // MARK: - Counting

    /// One successful dictation: text was recognized and handed to the user.
    ///
    /// This is what the ungated window is spent on, so what counts as one
    /// matters. A press that recognized nothing, a cancelled recording, and a
    /// failed transcription are not dictations and cost nothing — the user got
    /// no value and must not pay for it out of five.
    func recordSuccessfulDictation() {
        let now = clock()
        record.observe(now: now)
        let isFirst = record.firstDictationAt == nil
        if isFirst { record.firstDictationAt = now }
        record.successfulDictations += 1
        persist()
        if isFirst { telemetry.send(.trialStarted) }
        reevaluate()
    }

    // MARK: - Writing

    /// Accepts a key the user pasted.
    ///
    /// Verification happens before anything is stored, so a bad key leaves the
    /// record exactly as it was.
    @discardableResult
    func enter(key token: String) -> Result<License, LicenseKeyError> {
        do {
            let license = try LicenseKey.verify(token, authority: authority, deviceID: deviceID)
            record.licenseToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
            telemetry.send(.licenseAccepted(license.kind))
            Log.licensing.info("License accepted (\(license.kind.rawValue, privacy: .public))")
            reevaluate()
            return .success(license)
        } catch let error as LicenseKeyError {
            telemetry.send(.licenseRejected(error.rejectionReason))
            Log.licensing.notice("License refused: \(error.rejectionReason.rawValue, privacy: .public)")
            return .failure(error)
        } catch {
            telemetry.send(.licenseRejected(.malformed))
            return .failure(.malformed)
        }
    }

    /// Asks the activation service for a key for this Mac.
    ///
    /// The address is checked for shape here only so an obvious typo does not
    /// become a key mailed into nowhere; everything else is the service's
    /// decision.
    func requestActivation(email: String) async -> Result<License, ActivationError> {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailAddress.looksComplete(address) else {
            telemetry.send(.activationFailed(.invalidEmail))
            return .failure(.invalidEmail)
        }
        telemetry.send(.activationRequested)
        do {
            let token = try await backend.requestKey(email: address, deviceID: deviceID)
            switch enter(key: token) {
            case let .success(license):
                telemetry.send(.activationSucceeded)
                return .success(license)
            case let .failure(keyError):
                telemetry.send(.activationFailed(.rejected))
                return .failure(.rejected(keyError.message))
            }
        } catch let error as ActivationError {
            telemetry.send(.activationFailed(error.failureReason))
            return .failure(error)
        } catch {
            telemetry.send(.activationFailed(.unreachable))
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// Removes the license from this Mac. The key itself stays valid — this is
    /// how a user moves a Mac out of their two, not a punishment.
    func removeLicense() {
        guard record.licenseToken != nil else { return }
        record.licenseToken = nil
        persist()
        Log.licensing.info("License removed from this Mac")
        reevaluate()
    }

    func noteCheckoutOpened(_ offer: TelemetryEvent.Offer) {
        telemetry.send(.checkoutOpened(offer))
    }

    /// The price reached a screen. Sent by the paywall window, once per
    /// appearance — not once per press, and not when the lock is merely true.
    func notePaywallShown() {
        guard let lock = state.lock else { return }
        telemetry.send(.paywallShown(lock.paywallTrigger))
    }

    private func persist() {
        do {
            try store.save(record)
            storeErrorDescription = nil
        } catch {
            let message = (error as? EntitlementStoreError)?.message ?? error.localizedDescription
            storeErrorDescription = message
            Log.licensing.error("Usage record could not be saved: \(message, privacy: .public)")
        }
    }

    #if DEBUG
    /// Read by the tests that assert what the window is spent on.
    var successfulDictationCount: Int { record.successfulDictations }
    var trialStartedAt: Date? { record.firstDictationAt }
    #endif
}

extension EntitlementState {
    var logLabel: String {
        switch self {
        case let .ungated(standing): "ungated(\(standing.dictationsRemaining) left)"
        case let .licensed(license): "licensed(\(license.kind.rawValue))"
        case let .locked(lock): "locked(\(lock.logLabel))"
        }
    }
}

extension EntitlementLock {
    var logLabel: String {
        switch self {
        case .activationRequired: "activationRequired"
        case let .expired(kind, _): "expired:\(kind.rawValue)"
        }
    }

    var paywallTrigger: TelemetryEvent.PaywallTrigger {
        switch self {
        case .activationRequired: .activationRequired
        case let .expired(kind, _): kind == .trial ? .trialExpired : .licenseExpired
        }
    }
}

extension LicenseKeyError {
    var rejectionReason: TelemetryEvent.LicenseRejectionReason {
        switch self {
        case .malformed: .malformed
        case .unsupportedVersion: .unsupportedVersion
        case .noAuthority: .noAuthority
        case .badSignature: .badSignature
        case .wrongDevice: .wrongDevice
        case .inconsistentDates: .inconsistentDates
        }
    }
}

extension ActivationError {
    var failureReason: TelemetryEvent.ActivationFailureReason {
        switch self {
        case .notConfigured: .notConfigured
        case .invalidEmail: .invalidEmail
        case .unreachable: .unreachable
        case .rejected: .rejected
        case .deviceLimitReached: .deviceLimitReached
        }
    }
}

/// Where the two non-content fields in a product event come from.
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Major and minor only, deliberately. See `TelemetryEnvelope`.
    static var systemShort: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
