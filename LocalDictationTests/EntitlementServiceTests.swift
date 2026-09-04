import CryptoKit
import XCTest
@testable import Witness

/// The service that holds the licensing state together: what it counts, what it
/// stores, and what it refuses to believe from disk.
@MainActor
final class EntitlementServiceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = "test-device-0001"

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Date
        init(_ now: Date) { self.now = now }
        var value: Date { lock.withLock { now } }
        func advance(_ interval: TimeInterval) { lock.withLock { now += interval } }
        func set(_ date: Date) { lock.withLock { now = date } }
    }

    private func makeService(
        store: InMemoryEntitlementStore = InMemoryEntitlementStore(),
        authority: LicenseAuthority = LicenseAuthority(publicKeyBase64: ""),
        backend: any ActivationBackend = UnconfiguredActivationBackend(),
        telemetry: RecordingTelemetryService = RecordingTelemetryService(),
        clock: Clock
    ) -> EntitlementService {
        EntitlementService(
            store: store,
            authority: authority,
            deviceIdentity: FixedDeviceIdentity(device),
            backend: backend,
            telemetry: telemetry,
            clock: { clock.value }
        )
    }

    // MARK: - Counting

    /// The window is spent on text the user actually received. A press that
    /// recognized nothing is not a dictation, and the service is never told
    /// about one — that rule lives in the coordinator and is asserted there.
    func testFiveDictationsCloseTheWindow() {
        let clock = Clock(origin)
        let store = InMemoryEntitlementStore()
        let service = makeService(store: store, clock: clock)

        XCTAssertTrue(service.state.allowsDictation)
        for _ in 0..<5 {
            service.recordSuccessfulDictation()
            clock.advance(60)
        }

        XCTAssertEqual(service.state, .locked(.activationRequired))
        XCTAssertEqual(store.stored?.successfulDictations, 5)
    }

    func testTheTrialClockStartsAtTheFirstDictationAndNotAtInstall() {
        let clock = Clock(origin)
        let service = makeService(clock: clock)

        clock.advance(30 * 86_400)
        XCTAssertTrue(service.state.allowsDictation, "an app nobody has dictated into has not used a trial")

        service.recordSuccessfulDictation()
        XCTAssertEqual(service.trialStartedAt, origin.addingTimeInterval(30 * 86_400))
    }

    // MARK: - Keys

    func testAValidKeyUnlocksAndSurvivesARelaunch() throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let store = InMemoryEntitlementStore()
        let service = makeService(store: store, authority: authority, clock: clock)

        for _ in 0..<5 { service.recordSuccessfulDictation() }
        XCTAssertFalse(service.state.allowsDictation)

        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())
        XCTAssertEqual(service.state.license?.kind, .lifetime)

        // Relaunch: same store, new service. The token is re-verified rather
        // than trusted because it was on disk.
        let relaunched = makeService(store: store, authority: authority, clock: clock)
        XCTAssertEqual(relaunched.state.license?.kind, .lifetime)
    }

    func testARefusedKeyChangesNothing() {
        let clock = Clock(origin)
        let (authority, _) = TestLicenseIssuer.makeAuthority()
        let store = InMemoryEntitlementStore()
        let service = makeService(store: store, authority: authority, clock: clock)

        let result = service.enter(key: "LD1.bm90LWEta2V5.bm90LWEtc2ln")

        guard case .failure = result else { return XCTFail("a forged key must not be accepted") }
        XCTAssertNil(store.stored?.licenseToken)
        XCTAssertTrue(service.state.allowsDictation, "and the user keeps whatever they had before trying")
    }

    /// A key copied to a second Mac, or a build whose authority changed, leaves
    /// a token on disk that no longer verifies. It is discarded rather than
    /// shown as a license the user does not have.
    func testATokenThatStopsVerifyingIsDropped() throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let store = InMemoryEntitlementStore()
        let service = makeService(store: store, authority: authority, clock: clock)
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        let (otherAuthority, _) = TestLicenseIssuer.makeAuthority()
        let relaunched = makeService(store: store, authority: otherAuthority, clock: clock)

        XCTAssertNil(relaunched.state.license)
        XCTAssertNil(store.stored?.licenseToken)
    }

    func testRemovingALicenseReturnsTheMacToWhereItWas() throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let service = makeService(authority: authority, clock: clock)
        for _ in 0..<5 { service.recordSuccessfulDictation() }
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        service.removeLicense()

        XCTAssertEqual(service.state, .locked(.activationRequired))
    }

    /// A trial that runs out while the app is open has to be noticed without a
    /// relaunch, which is why the verdict is recomputed and never cached.
    func testATrialExpiringWhileTheAppIsOpenIsNoticedOnRefresh() throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let expiry = origin.addingTimeInterval(EntitlementPolicy.trialDuration)
        let service = makeService(authority: authority, clock: clock)
        let token = try TestLicenseIssuer.issue(kind: .trial, deviceID: device, expiresAt: expiry, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())
        XCTAssertTrue(service.state.allowsDictation)

        clock.set(expiry.addingTimeInterval(1))
        service.refresh()

        XCTAssertEqual(service.state, .locked(.expired(.trial, at: expiry)))
    }

    // MARK: - Activation

    func testActivationSendsTheAddressAndTheDeviceAndNothingElse() async throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(
            kind: .trial,
            deviceID: device,
            expiresAt: origin.addingTimeInterval(EntitlementPolicy.trialDuration),
            signingKey: signingKey
        )
        let backend = FakeActivationBackend(result: .success(token))
        let service = makeService(authority: authority, backend: backend, clock: clock)

        let result = await service.requestActivation(email: " owner@example.com ")

        guard case .success = result else { return XCTFail("activation should have succeeded") }
        XCTAssertEqual(backend.lastEmail, "owner@example.com")
        XCTAssertEqual(backend.lastDeviceID, device)
        XCTAssertEqual(service.state.license?.kind, .trial)
    }

    func testAnIncompleteAddressNeverReachesTheNetwork() async {
        let clock = Clock(origin)
        let backend = FakeActivationBackend()
        let service = makeService(backend: backend, clock: clock)

        let result = await service.requestActivation(email: "owner@example")

        guard case let .failure(error) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(error, .invalidEmail)
        XCTAssertEqual(backend.requestCount, 0)
    }

    /// What ships until there is a service: a refusal that names the other way
    /// in, rather than a stub that pretends to have succeeded.
    func testTheDefaultBackendRefusesInsteadOfPretending() async {
        let clock = Clock(origin)
        let service = makeService(clock: clock)

        let result = await service.requestActivation(email: "owner@example.com")

        guard case let .failure(error) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(error, .notConfigured)
        XCTAssertFalse(service.canRequestActivation)
    }

    // MARK: - Giving a Mac back

    /// The order is what is being asserted. The key is the only proof this Mac
    /// holds, so it has to reach the service before it is thrown away.
    func testReleasingTellsTheServiceBeforeItRemovesTheKey() async throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend()
        let service = makeService(authority: authority, backend: backend, clock: clock)
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        let outcome = await service.releaseFromThisMac()

        XCTAssertEqual(outcome, .releasedEverywhere)
        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertEqual(backend.releasedKey, token)
        XCTAssertEqual(backend.releasedDeviceID, device)
        XCTAssertNil(service.state.license)
    }

    /// A server having a bad day is not a reason to strand somebody with a
    /// license they cannot move. The local half happens anyway, and the user is
    /// told the slot did not come free.
    func testAServiceThatCannotBeReachedStillLetsTheMacGo() async throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend()
        backend.setReleaseError(.unreachable("no network"))
        let service = makeService(authority: authority, backend: backend, clock: clock)
        for _ in 0..<5 { service.recordSuccessfulDictation() }
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        let outcome = await service.releaseFromThisMac()

        guard case let .removedLocallyOnly(message) = outcome else {
            return XCTFail("expected the local-only outcome, got \(outcome)")
        }
        XCTAssertTrue(message.contains("no network"))
        XCTAssertNil(service.state.license)
        // The Mac goes back to exactly where it was before the key arrived,
        // which for a used-up window is the wall.
        XCTAssertEqual(service.state, .locked(.activationRequired))
        XCTAssertEqual(backend.releaseCount, 1)
    }

    /// A build with no service configured removes the license and says nothing
    /// about slots, because it has nothing to say about them.
    func testWithNoServiceReleasingIsJustRemoving() async throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend(isConfigured: false)
        let service = makeService(authority: authority, backend: backend, clock: clock)
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        let outcome = await service.releaseFromThisMac()

        XCTAssertEqual(outcome, .removedLocally)
        XCTAssertEqual(backend.releaseCount, 0)
        XCTAssertNil(service.state.license)
    }

    /// A key the service has never heard of — which is every key issued by hand
    /// with `Tools/licensekit.swift` before the service existed. The Mac ends up
    /// exactly where its owner wanted it, so it reads as a plain removal and not
    /// as a warning about a slot that was never held.
    func testAKeyTheServiceHasNoRecordOfIsStillACleanRemoval() async throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend()
        backend.releaseFreedASlot = false
        let service = makeService(authority: authority, backend: backend, clock: clock)
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        let outcome = await service.releaseFromThisMac()

        XCTAssertEqual(outcome, .removedLocally)
        XCTAssertEqual(backend.releaseCount, 1, "it still asked")
        XCTAssertNil(service.state.license)
    }

    /// Nothing to release, nothing sent. Pressing the button on a Mac that has
    /// no license must not spend a slot on the service.
    func testReleasingWithoutALicenseTellsNobody() async {
        let clock = Clock(origin)
        let backend = FakeActivationBackend()
        let service = makeService(backend: backend, clock: clock)

        let outcome = await service.releaseFromThisMac()

        XCTAssertEqual(outcome, .removedLocally)
        XCTAssertEqual(backend.releaseCount, 0)
    }

    // MARK: - Telemetry

    /// Every product event this app can emit comes from the licensing flow, and
    /// none of them can carry anything the user said.
    func testTheFunnelEventsAreTheOnesThatWereEnumerated() async throws {
        let clock = Clock(origin)
        let telemetry = RecordingTelemetryService()
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let service = makeService(authority: authority, telemetry: telemetry, clock: clock)

        service.recordSuccessfulDictation()
        for _ in 0..<4 { service.recordSuccessfulDictation() }
        // The window is used up and the Mac is locked — and that on its own
        // sends nothing. A lock is a fact about a Mac; a paywall is a fact
        // about a person, and only the second one is worth money.
        XCTAssertEqual(telemetry.names, ["installed", "trial_started"])

        service.notePaywallShown()
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        XCTAssertEqual(
            telemetry.names,
            ["installed", "trial_started", "paywall_shown", "license_accepted"]
        )
    }

    /// Nobody is shown a price on a Mac that is working, whoever asks.
    func testAPaywallIsNotReportedOnAMacThatIsNotLocked() throws {
        let clock = Clock(origin)
        let telemetry = RecordingTelemetryService()
        let service = makeService(telemetry: telemetry, clock: clock)

        service.recordSuccessfulDictation()
        service.notePaywallShown()

        XCTAssertEqual(telemetry.names, ["installed", "trial_started"])
    }
}
