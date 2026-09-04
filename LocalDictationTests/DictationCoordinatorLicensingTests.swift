import CryptoKit
import XCTest
@testable import Witness

/// What licensing does to dictation, which is the only part of it the user
/// experiences.
///
/// Two rules are worth more than the rest and both are asserted here: a locked
/// Mac never opens the microphone, and a lock that arrives mid-utterance never
/// costs the user the words they had already said.
@MainActor
final class DictationCoordinatorLicensingTests: XCTestCase {
    private let device = "test-device-0001"

    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let capture: FakeAudioCaptureService
        let engine: FakeTranscriptionService
        let entitlement: EntitlementService
        let store: InMemoryEntitlementStore
        let signingKey: Curve25519.Signing.PrivateKey
    }

    private func makeHarness(text: String = "der termin steht") -> Harness {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(text: text, profile: .german))
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
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let store = InMemoryEntitlementStore()
        let entitlement = EntitlementService(
            store: store,
            authority: authority,
            deviceIdentity: FixedDeviceIdentity(device),
            backend: UnconfiguredActivationBackend(),
            telemetry: RecordingTelemetryService(),
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
        return Harness(
            coordinator: coordinator,
            hotkey: hotkey,
            capture: capture,
            engine: engine,
            entitlement: entitlement,
            store: store,
            signingKey: signingKey
        )
    }

    private func dictate(_ harness: Harness) async throws {
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("result ready") { harness.coordinator.result != nil }
    }

    /// The ungated window: five dictations, no email, no key, no interruption.
    func testTheFirstFiveDictationsAskForNothing() async throws {
        let harness = makeHarness()

        for _ in 0..<5 {
            try await dictate(harness)
            harness.coordinator.clearTranscript()
        }

        XCTAssertEqual(harness.store.stored?.successfulDictations, 5)
    }

    /// The fifth dictation is still delivered in full. The lock it produces
    /// applies to the press after it — text the user has already spoken has
    /// been earned, and taking it away to enforce a trial would be the worst
    /// thing this feature could do.
    func testTheDictationThatClosesTheWindowStillArrives() async throws {
        let harness = makeHarness()

        for index in 0..<5 {
            try await dictate(harness)
            // The last result is left in place — it is what the assertion below
            // is about.
            if index < 4 { harness.coordinator.clearTranscript() }
        }

        XCTAssertEqual(harness.coordinator.result?.cleanedText, "Der termin steht.")
        XCTAssertEqual(harness.coordinator.entitlement, .locked(.activationRequired))
    }

    func testALockedMacNeverOpensTheMicrophone() async throws {
        let harness = makeHarness()
        for _ in 0..<5 {
            try await dictate(harness)
            harness.coordinator.clearTranscript()
        }
        try await waitUntil("locked") { harness.coordinator.state == .locked(.activationRequired) }
        let startsBefore = harness.capture.startCount
        let stopsBefore = harness.capture.stopCount

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        // The start is inside a `Task`, so an assertion on the next line runs
        // before the microphone would have opened and passes whatever the
        // coordinator does. This test read that way once, and underneath it a
        // locked press opened the microphone and never closed it: `.locked ->
        // .locked` is a transition, a transition reads as success, and every
        // event that would have ended the capture is refused in `.locked`.
        try await settle()

        XCTAssertEqual(harness.capture.startCount, startsBefore, "a locked Mac must not record")
        XCTAssertEqual(harness.capture.stopCount, stopsBefore, "nothing was started, so nothing needed stopping")
        XCTAssertEqual(harness.coordinator.state, .locked(.activationRequired))
    }

    /// The press is the ask, and the ask is what the price answers.
    func testALockedPressAsksForThePaywall() async throws {
        let harness = makeHarness()
        for _ in 0..<5 {
            try await dictate(harness)
            harness.coordinator.clearTranscript()
        }
        try await waitUntil("locked") { harness.coordinator.state == .locked(.activationRequired) }
        // Becoming locked is not a request. A Mac can lock in the background,
        // at launch, with nobody looking at it.
        XCTAssertEqual(harness.coordinator.paywallRequests, 0)

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await settle()
        XCTAssertEqual(harness.coordinator.paywallRequests, 1)

        // Someone who closed the window and pressed again is asking again.
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await settle()
        XCTAssertEqual(harness.coordinator.paywallRequests, 2)
    }

    /// A working Mac is never sold to.
    func testAnUnlockedPressAsksForNothing() async throws {
        let harness = makeHarness()
        try await dictate(harness)

        XCTAssertEqual(harness.coordinator.paywallRequests, 0)
        XCTAssertEqual(harness.coordinator.entitlement.lock, nil)
    }

    /// Long enough for a `Task` enqueued by the press to have run. Anything
    /// asserted about capture straight after an emit is asserted too early.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    /// A press that recognized nothing produced no value, so it costs nothing.
    /// Two utterances of nine seconds came back empty on a real Mac while Phase
    /// 4 was being measured; charging a user a fifth of their window for that
    /// would be indefensible.
    func testADictationThatRecognizesNothingIsNotCounted() async throws {
        let harness = makeHarness(text: "")

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("back to ready") { harness.coordinator.state == .ready }

        XCTAssertEqual(harness.entitlement.successfulDictationCount, 0)
        XCTAssertTrue(harness.coordinator.entitlement.allowsDictation)
    }

    func testAKeyUnlocksTheHotkeyImmediately() async throws {
        let harness = makeHarness()
        for _ in 0..<5 {
            try await dictate(harness)
            harness.coordinator.clearTranscript()
        }
        try await waitUntil("locked") { harness.coordinator.state == .locked(.activationRequired) }

        let token = try TestLicenseIssuer.issue(
            kind: .lifetime,
            deviceID: device,
            expiresAt: nil,
            signingKey: harness.signingKey
        )
        XCTAssertNil(harness.coordinator.enterLicenseKey(token))

        XCTAssertEqual(harness.coordinator.state, .ready)
        try await dictate(harness)
        XCTAssertEqual(harness.coordinator.result?.cleanedText, "Der termin steht.")
    }

    func testARefusedKeyLeavesTheMacLockedAndSaysWhy() async throws {
        let harness = makeHarness()
        for _ in 0..<5 {
            try await dictate(harness)
            harness.coordinator.clearTranscript()
        }
        try await waitUntil("locked") { harness.coordinator.state == .locked(.activationRequired) }

        let foreign = try TestLicenseIssuer.issue(
            kind: .lifetime,
            deviceID: "someone-elses-mac",
            expiresAt: nil,
            signingKey: harness.signingKey
        )

        XCTAssertEqual(harness.coordinator.enterLicenseKey(foreign), .wrongDevice(issuedFor: "someone-elses-mac"))
        XCTAssertEqual(harness.coordinator.state, .locked(.activationRequired))
    }

    /// Without a licensing service the app is in the Phase 5 world and gates
    /// nothing. Every other coordinator test in this suite depends on it.
    func testAnAppWithoutLicensingGatesNothing() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(text: "der termin steht", profile: .german))
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService(),
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            languageProfile: .german
        )
        coordinator.activate()

        XCTAssertFalse(coordinator.hasEntitlementService)
        XCTAssertEqual(coordinator.state, .ready)
        for _ in 0..<10 {
            hotkey.emit(.pressed)
            hotkey.emit(.released)
            try await waitUntil("result") { coordinator.result != nil }
            coordinator.clearTranscript()
        }
        XCTAssertEqual(coordinator.state, .ready)
    }
}
