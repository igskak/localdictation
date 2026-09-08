import CryptoKit
import XCTest
@testable import Witness

/// The service that holds the licensing state together: what it counts, what it
/// stores, and what it refuses to believe from disk.
@MainActor
final class EntitlementServiceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = "test-device-0001"

    /// Shared with the other suites that have to watch a window close.
    private typealias Clock = TestClock

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

    /// Dictates once to start the clock, then steps past the three ungated
    /// days. The window is time, so this is the only way to the wall.
    private func spendTheUngatedWindow(_ service: EntitlementService, _ clock: Clock) {
        service.recordSuccessfulDictation()
        clock.advance(EntitlementPolicy.ungatedDuration + 60)
        service.refresh()
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

        // However much is dictated, the window is time and not presses.
        for _ in 0..<20 {
            service.recordSuccessfulDictation()
            clock.advance(60)
        }
        XCTAssertTrue(service.state.allowsDictation, "twenty dictations inside the window cost nothing")

        clock.advance(EntitlementPolicy.ungatedDuration)
        service.refresh()

        XCTAssertEqual(service.state, .locked(.activationRequired))
        XCTAssertEqual(store.stored?.firstDictationAt, origin)
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

        spendTheUngatedWindow(service, clock)
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
        spendTheUngatedWindow(service, clock)
        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        service.removeLicense()

        XCTAssertEqual(service.state, .locked(.activationRequired))
    }

    // MARK: - What the window says after activating

    /// The whole path a stranger takes, and what Settings → License shows at
    /// the end of it: dictate, hit the wall on the fourth day, type an address,
    /// and get a screen that says the trial is running and how long is left.
    ///
    /// Asserted end to end rather than by constructing a `.licensed` state,
    /// because the thing worth checking is that the state actually *moves* —
    /// the view reads `coordinator.entitlement`, and a service that unlocked
    /// without republishing would leave the user looking at the wall they had
    /// just paid an address to get past.
    func testActivatingAtTheWallLeavesTheWindowShowingARunningTrial() async throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend()
        let service = makeService(authority: authority, backend: backend, clock: clock)

        spendTheUngatedWindow(service, clock)
        XCTAssertEqual(LicensePresentation(state: service.state, now: clock.value).headline, "Activate to keep dictating")

        // What the service issues: ten days from the moment of activation.
        let expiry = clock.value.addingTimeInterval(EntitlementPolicy.trialDuration)
        backend.setResult(.success(try TestLicenseIssuer.issue(
            kind: .trial,
            deviceID: device,
            expiresAt: expiry,
            signingKey: signingKey
        )))

        var changes: [EntitlementState] = []
        service.onChange = { changes.append($0) }
        let issued = await service.requestActivation(email: "someone@example.com")
        XCTAssertEqual(try issued.get().kind, .trial)

        XCTAssertTrue(service.state.allowsDictation)
        XCTAssertEqual(service.state.license?.kind, .trial)
        XCTAssertEqual(changes.last?.license?.kind, .trial, "the view is told, rather than having to ask again")

        let presentation = LicensePresentation(state: service.state, now: clock.value)
        XCTAssertEqual(presentation.headline, "Trial, activated")
        XCTAssertTrue(presentation.detail.contains("10 days left"), presentation.detail)
        XCTAssertFalse(presentation.showsActivation, "the form that was just used is no longer the thing to do")
        XCTAssertTrue(presentation.showsOffers, "a running trial is where the offers belong")
    }

    /// And the count comes down as the days do, without a relaunch.
    func testTheDaysLeftFallAsTheTrialRuns() throws {
        let clock = Clock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let service = makeService(authority: authority, clock: clock)
        let expiry = origin.addingTimeInterval(EntitlementPolicy.trialDuration)
        let token = try TestLicenseIssuer.issue(kind: .trial, deviceID: device, expiresAt: expiry, signingKey: signingKey)
        XCTAssertNoThrow(try service.enter(key: token).get())

        for (elapsedDays, expected) in [(0.0, "10 days left"), (4.0, "6 days left"), (9.5, "1 day left")] {
            clock.set(origin.addingTimeInterval(elapsedDays * 86_400))
            service.refresh()

            let presentation = LicensePresentation(state: service.state, now: clock.value)
            XCTAssertTrue(presentation.detail.contains(expected), "day \(elapsedDays): \(presentation.detail)")
        }
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
        spendTheUngatedWindow(service, clock)
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

        spendTheUngatedWindow(service, clock)
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
