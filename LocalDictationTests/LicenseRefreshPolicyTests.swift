import XCTest
@testable import Witness

/// When a subscription key is replaced, and what the app does when the service
/// answers. The dates are the whole of the rule, so most of this is two dates.
@MainActor
final class LicenseRefreshPolicyTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = "test-device-0001"

    private func license(_ kind: LicenseKind, expiresIn seconds: TimeInterval?) -> License {
        License(
            id: "lic",
            email: "owner@example.com",
            kind: kind,
            deviceID: device,
            issuedAt: origin.addingTimeInterval(-86_400),
            expiresAt: seconds.map { origin.addingTimeInterval($0) }
        )
    }

    // MARK: - The policy

    func testAKeyWithMoreThanAWeekLeftIsLeftAlone() {
        XCTAssertFalse(LicenseRefreshPolicy.isDue(license: license(.annual, expiresIn: 8 * 86_400), now: origin, lastAttempt: nil))
    }

    func testAKeyInItsLastWeekIsDue() {
        XCTAssertTrue(LicenseRefreshPolicy.isDue(license: license(.annual, expiresIn: 7 * 86_400), now: origin, lastAttempt: nil))
        XCTAssertTrue(LicenseRefreshPolicy.isDue(license: license(.annual, expiresIn: 3_600), now: origin, lastAttempt: nil))
    }

    func testAKeyThatAlreadyRanOutIsStillDue() {
        XCTAssertTrue(LicenseRefreshPolicy.isDue(license: license(.annual, expiresIn: -86_400), now: origin, lastAttempt: nil))
    }

    func testOnlyAnnualKeysAreRefreshed() {
        XCTAssertFalse(LicenseRefreshPolicy.isDue(license: license(.trial, expiresIn: 3_600), now: origin, lastAttempt: nil))
        XCTAssertFalse(LicenseRefreshPolicy.isDue(license: license(.lifetime, expiresIn: nil), now: origin, lastAttempt: nil))
        XCTAssertFalse(LicenseRefreshPolicy.isDue(license: nil, now: origin, lastAttempt: nil))
    }

    func testItAsksOnceAnHourWhileTheKeyIsGood() {
        let current = license(.annual, expiresIn: 3 * 86_400)
        XCTAssertFalse(LicenseRefreshPolicy.isDue(license: current, now: origin, lastAttempt: origin.addingTimeInterval(-1_800)))
        XCTAssertTrue(LicenseRefreshPolicy.isDue(license: current, now: origin, lastAttempt: origin.addingTimeInterval(-3_700)))
    }

    func testItAsksMoreOftenOnceTheKeyHasRunOut() {
        let current = license(.annual, expiresIn: -60)
        XCTAssertFalse(LicenseRefreshPolicy.isDue(license: current, now: origin, lastAttempt: origin.addingTimeInterval(-120)))
        XCTAssertTrue(LicenseRefreshPolicy.isDue(license: current, now: origin, lastAttempt: origin.addingTimeInterval(-400)))
    }

    func testAnEarlierOrEqualKeyIsNotAnImprovement() {
        let current = license(.annual, expiresIn: 3 * 86_400)
        XCTAssertFalse(LicenseRefreshPolicy.isImprovement(current, over: current))
        XCTAssertTrue(LicenseRefreshPolicy.isImprovement(license(.annual, expiresIn: 33 * 86_400), over: current))
        XCTAssertFalse(LicenseRefreshPolicy.isImprovement(license(.annual, expiresIn: 86_400), over: current))
    }

    // MARK: - The service

    private func makeService(
        store: InMemoryEntitlementStore,
        authority: LicenseAuthority,
        backend: FakeActivationBackend,
        clock: TestClock
    ) -> EntitlementService {
        EntitlementService(
            store: store,
            authority: authority,
            deviceIdentity: FixedDeviceIdentity(device),
            backend: backend,
            telemetry: RecordingTelemetryService(),
            clock: { clock.value }
        )
    }

    func testAKeyInItsLastWeekIsReplacedWithoutAnyoneAsking() async throws {
        let clock = TestClock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let store = InMemoryEntitlementStore()
        let backend = FakeActivationBackend()
        let service = makeService(store: store, authority: authority, backend: backend, clock: clock)

        let old = try TestLicenseIssuer.issue(
            kind: .annual, deviceID: device, issuedAt: origin.addingTimeInterval(-25 * 86_400),
            expiresAt: origin.addingTimeInterval(5 * 86_400), signingKey: signingKey
        )
        XCTAssertNoThrow(try service.enter(key: old).get())

        let fresh = try TestLicenseIssuer.issue(
            kind: .annual, deviceID: device, issuedAt: origin.addingTimeInterval(-25 * 86_400),
            expiresAt: origin.addingTimeInterval(35 * 86_400), signingKey: signingKey
        )
        backend.setResult(.success(fresh))

        await service.refreshSubscriptionKeyIfDue()

        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(backend.lastEmail, "owner@example.com", "the address the key was issued to, not one typed")
        XCTAssertEqual(service.license?.expiresAt, origin.addingTimeInterval(35 * 86_400))
        XCTAssertEqual(store.stored?.licenseToken, fresh)
    }

    func testAKeyWithTimeLeftDoesNotCallTheService() async throws {
        let clock = TestClock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend()
        let service = makeService(store: InMemoryEntitlementStore(), authority: authority, backend: backend, clock: clock)

        let key = try TestLicenseIssuer.issue(
            kind: .annual, deviceID: device, issuedAt: origin, expiresAt: origin.addingTimeInterval(20 * 86_400), signingKey: signingKey
        )
        XCTAssertNoThrow(try service.enter(key: key).get())

        await service.refreshSubscriptionKeyIfDue()
        XCTAssertEqual(backend.requestCount, 0)
    }

    func testAFailedRefreshChangesNothingAndIsNotRepeatedAtOnce() async throws {
        let clock = TestClock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend(result: .failure(.unreachable("offline")))
        let service = makeService(store: InMemoryEntitlementStore(), authority: authority, backend: backend, clock: clock)

        let key = try TestLicenseIssuer.issue(
            kind: .annual, deviceID: device, issuedAt: origin, expiresAt: origin.addingTimeInterval(2 * 86_400), signingKey: signingKey
        )
        XCTAssertNoThrow(try service.enter(key: key).get())

        await service.refreshSubscriptionKeyIfDue()
        await service.refreshSubscriptionKeyIfDue()

        XCTAssertEqual(backend.requestCount, 1, "the second call is inside the hour")
        XCTAssertEqual(service.license?.expiresAt, origin.addingTimeInterval(2 * 86_400))
    }

    func testARefusedRefreshLeavesTheKeyToRunOut() async throws {
        let clock = TestClock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend(result: .failure(.subscriptionInactive))
        let service = makeService(store: InMemoryEntitlementStore(), authority: authority, backend: backend, clock: clock)

        let key = try TestLicenseIssuer.issue(
            kind: .annual, deviceID: device, issuedAt: origin, expiresAt: origin.addingTimeInterval(2 * 86_400), signingKey: signingKey
        )
        XCTAssertNoThrow(try service.enter(key: key).get())

        await service.refreshSubscriptionKeyIfDue()
        XCTAssertNotNil(service.license, "nothing is revoked on the Mac; the key simply ends on its date")

        clock.advance(3 * 86_400)
        service.refresh()
        XCTAssertEqual(service.state.lock, .expired(.annual, at: origin.addingTimeInterval(2 * 86_400)))
    }

    func testAKeyForAnotherMacIsNotStored() async throws {
        let clock = TestClock(origin)
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let backend = FakeActivationBackend()
        let service = makeService(store: InMemoryEntitlementStore(), authority: authority, backend: backend, clock: clock)

        let key = try TestLicenseIssuer.issue(
            kind: .annual, deviceID: device, issuedAt: origin, expiresAt: origin.addingTimeInterval(2 * 86_400), signingKey: signingKey
        )
        XCTAssertNoThrow(try service.enter(key: key).get())

        backend.setResult(.success(try TestLicenseIssuer.issue(
            kind: .annual, deviceID: "another-mac", issuedAt: origin, expiresAt: origin.addingTimeInterval(40 * 86_400), signingKey: signingKey
        )))
        await service.refreshSubscriptionKeyIfDue()

        XCTAssertEqual(service.license?.expiresAt, origin.addingTimeInterval(2 * 86_400))
    }
}
