import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import LocalDictation

/// The window that names the price, driven through real AppKit layout.
///
/// Same reasoning as `LanguageSetupTests`: this is a SwiftUI view nobody sees
/// until a particular day in a particular install, and a view that crashes the
/// first time it appears passes every unit test that never lays it out.
@MainActor
final class PaywallWindowTests: XCTestCase {
    private let device = "test-device-0002"

    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let telemetry: RecordingTelemetryService
    }

    private func makeHarness() -> Harness {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(text: "der termin steht", profile: .german))
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        capture.setSnapshot(
            CaptureSnapshot(
                frameCount: 16_000,
                capacityFrames: 1_920_000,
                peakLevel: 0.4,
                sampleRate: AudioTargetFormat.sampleRate
            )
        )
        let telemetry = RecordingTelemetryService()
        let entitlement = EntitlementService(
            store: InMemoryEntitlementStore(),
            authority: LicenseAuthority(publicKeyBase64: ""),
            deviceIdentity: FixedDeviceIdentity(device),
            backend: UnconfiguredActivationBackend(),
            telemetry: telemetry,
            clock: { Date() }
        )
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            fragmentPlayer: FakeAudioFragmentPlayer(),
            insertionService: FakeTextInsertionService(),
            entitlementService: entitlement,
            languageProfile: .german
        )
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, telemetry: telemetry)
    }

    /// Spends the ungated window the way a user does.
    private func lock(_ harness: Harness) async throws {
        for _ in 0..<5 {
            harness.hotkey.emit(.pressed)
            harness.hotkey.emit(.released)
            try await waitUntil("result") { harness.coordinator.result != nil }
            harness.coordinator.clearTranscript()
        }
        try await waitUntil("locked") { harness.coordinator.entitlement.lock != nil }
    }

    private func settle(_ turns: Int = 4) async throws {
        for _ in 0..<turns {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @discardableResult
    private func render(_ view: some View) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 320)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.removeFromSuperview()
        return size
    }

    // MARK: - Layout

    func testThePaywallLaysOutWhenActivationIsWhatIsAsked() async throws {
        let harness = makeHarness()
        try await lock(harness)
        XCTAssertEqual(harness.coordinator.entitlement, .locked(.activationRequired))

        let size = render(PaywallView(coordinator: harness.coordinator, openLicenseSettings: {}, dismiss: {}))

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: - Who gets the address form

    /// The paywall is where somebody stands when they come back from paying,
    /// and a license bought in a browser becomes a key on this Mac only when
    /// the address is handed over from inside the app.
    func testTheFormAppearsForSomebodyWhoHasAlreadyPaid() {
        let expired = LicensePresentation(state: .locked(.expired(.trial, at: Date())))
        XCTAssertFalse(expired.showsActivation, "the trial is over; starting one is not the ask")
        XCTAssertTrue(expired.offersKeyRetrieval)

        XCTAssertTrue(
            PaywallView.showsActivationForm(expired, canRequestActivation: true),
            "somebody who just bought needs somewhere to type the address they bought with"
        )
        XCTAssertFalse(
            PaywallView.showsActivationForm(expired, canRequestActivation: false),
            "a form that can only refuse is worse than no form"
        )
    }

    /// The window that ends the ungated one asks for an address whether or not
    /// there is a service today — the sentence under it says which it is.
    func testTheFormAlwaysAppearsWhenActivationIsTheAsk() {
        let needsActivation = LicensePresentation(state: .locked(.activationRequired))
        XCTAssertTrue(needsActivation.showsActivation)

        for configured in [true, false] {
            XCTAssertTrue(
                PaywallView.showsActivationForm(needsActivation, canRequestActivation: configured),
                "activation is the whole ask in this state"
            )
        }
    }

    // MARK: - The window

    func testAPressPutsThePriceOnScreenAndCountsItOnce() async throws {
        let harness = makeHarness()
        let controller = PaywallWindowController(coordinator: harness.coordinator)
        try await lock(harness)

        // Locking on its own shows nobody anything.
        try await settle()
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(harness.telemetry.names.contains("paywall_shown"))

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("the price is on screen") { controller.isShowing }

        XCTAssertTrue(controller.isShowing, "the press is what asks, and the price is the answer")
        XCTAssertEqual(harness.telemetry.names.filter { $0 == "paywall_shown" }.count, 1)

        // A second press while it is already in front of them is not a second
        // showing, and must not be counted as one.
        let window = controller.window
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await settle()

        XCTAssertIdentical(controller.window, window)
        XCTAssertEqual(harness.telemetry.names.filter { $0 == "paywall_shown" }.count, 1)

        controller.close()
    }

    func testTheWallComesDownWhenTheMacIsLicensed() async throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let telemetry = RecordingTelemetryService()
        let entitlement = EntitlementService(
            store: InMemoryEntitlementStore(),
            authority: authority,
            deviceIdentity: FixedDeviceIdentity(device),
            backend: UnconfiguredActivationBackend(),
            telemetry: telemetry,
            clock: { Date() }
        )
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(text: "der termin steht", profile: .german))
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        capture.setSnapshot(
            CaptureSnapshot(
                frameCount: 16_000,
                capacityFrames: 1_920_000,
                peakLevel: 0.4,
                sampleRate: AudioTargetFormat.sampleRate
            )
        )
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            fragmentPlayer: FakeAudioFragmentPlayer(),
            insertionService: FakeTextInsertionService(),
            entitlementService: entitlement,
            languageProfile: .german
        )
        coordinator.activate()
        let controller = PaywallWindowController(coordinator: coordinator)
        try await lock(Harness(coordinator: coordinator, hotkey: hotkey, telemetry: telemetry))

        hotkey.emit(.pressed)
        hotkey.emit(.released)
        try await waitUntil("the price is on screen") { controller.isShowing }

        let token = try TestLicenseIssuer.issue(kind: .lifetime, deviceID: device, expiresAt: nil, signingKey: signingKey)
        XCTAssertNil(coordinator.enterLicenseKey(token))
        // Waited for rather than slept through: the whole suite runs its
        // classes in parallel, and a fixed sleep that is long enough on an idle
        // Mac is a flake on a busy one.
        try await waitUntil("the wall comes down") { !controller.isShowing }

        XCTAssertFalse(controller.isShowing, "a wall that outlives the lock reads as a payment that did not register")
        XCTAssertNil(controller.window)
    }
}
