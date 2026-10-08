import XCTest
@testable import Witness

/// What the app reports about the stretch between a download and a first
/// dictation, asserted at the call sites rather than at the enum.
///
/// The question these events were added for is not a licensing question: eight
/// genuine downloads had produced no `trial_started` at all, and nothing in the
/// data could say whether the app had launched, whether the 1.6 GB had arrived,
/// or whether somebody was holding the key into a wait. `EntitlementServiceTests`
/// covers the once-per-install rule; this file covers whether the five facts
/// are reported at the moments they claim to describe.
@MainActor
final class SetupFunnelTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let engine: FakeTranscriptionService
        let telemetry: RecordingTelemetryService
        let permissions: FakeMicrophonePermissionService
    }

    private func makeHarness(
        modelState: TranscriptionModelState = .ready,
        microphone: MicrophoneAuthorization = .authorized,
        answersMicrophoneWith answer: MicrophoneAuthorization = .authorized
    ) -> Harness {
        let engine = FakeTranscriptionService()
        engine.setModelState(modelState)
        let hotkey = FakeHotkeyService()
        let telemetry = RecordingTelemetryService()
        let permissions = FakeMicrophonePermissionService(
            authorization: microphone,
            requestResult: answer
        )
        let entitlement = EntitlementService(
            store: InMemoryEntitlementStore(),
            authority: LicenseAuthority(publicKeyBase64: ""),
            deviceIdentity: FixedDeviceIdentity("test-device-0001"),
            backend: UnconfiguredActivationBackend(),
            telemetry: telemetry,
            clock: { Date() }
        )
        let coordinator = DictationCoordinator(
            permissionService: permissions,
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService(),
            transcriptionService: engine,
            entitlementService: entitlement
        )
        coordinator.activate()
        return Harness(
            coordinator: coordinator,
            hotkey: hotkey,
            engine: engine,
            telemetry: telemetry,
            permissions: permissions
        )
    }

    /// The names without `installed`, which every harness sends at construction
    /// and which is never the fact under test here.
    private func setupEvents(_ telemetry: RecordingTelemetryService) -> [String] {
        telemetry.names.filter { $0 != "installed" }
    }

    /// A first launch: the weights are missing, the app fetches them itself, and
    /// both ends of that wait are reported.
    func testAFirstLaunchReportsTheFetchAndThenTheModelBeingReady() async throws {
        let harness = makeHarness(
            modelState: .unavailable("the speech model has not been downloaded yet", needsUserAction: true)
        )

        try await waitUntil("the launch fetch finishes") { harness.coordinator.transcriptionModelState.isReady }

        XCTAssertEqual(setupEvents(harness.telemetry), ["model_download_started", "model_ready"])
        // A fake engine returns at once, so the bucket is the shortest one.
        XCTAssertEqual(harness.telemetry.recorded.last, .modelReady(.underOneMinute))
    }

    /// A later launch finds the weights on disk. Nothing is downloading, so
    /// nothing says it is.
    func testALaunchThatOnlyLoadsReportsNoDownload() async throws {
        let harness = makeHarness(
            modelState: .unavailable("installed but not loaded", needsUserAction: false)
        )

        try await waitUntil("the load finishes") { harness.coordinator.transcriptionModelState.isReady }

        XCTAssertEqual(setupEvents(harness.telemetry), ["model_ready"])
    }

    /// The failure carries the engine's own classification, not a reading of
    /// its sentence.
    func testAFailedFetchIsReportedWithItsReason() async throws {
        let harness = makeHarness(
            modelState: .unavailable("the speech model has not been downloaded yet", needsUserAction: true)
        )
        harness.engine.failPreparation(
            with: .modelPreparationFailed(.storage, detail: "No space left on device")
        )

        try await waitUntil("the launch fetch fails") {
            if case .failed = harness.coordinator.transcriptionModelState { return true }
            return false
        }

        XCTAssertEqual(setupEvents(harness.telemetry), ["model_download_started", "model_failed"])
        XCTAssertEqual(harness.telemetry.recorded.last, .modelFailed(.storage))
    }

    /// An error that reaches the coordinator without a classification is
    /// `other`, which is the whole of what an unclassified failure may claim.
    func testAnUnclassifiedFailureIsReportedAsOther() async throws {
        let harness = makeHarness(
            modelState: .unavailable("installed but not loaded", needsUserAction: false)
        )
        harness.engine.failPreparation(with: .modelUnavailable("something nobody has seen"))

        try await waitUntil("the load fails") {
            if case .failed = harness.coordinator.transcriptionModelState { return true }
            return false
        }

        XCTAssertEqual(harness.telemetry.recorded.last, .modelFailed(.other))
    }

    /// The press into the wait: the one event here about a person rather than a
    /// machine, and the reason the wait can be seen being suffered instead of
    /// inferred from a gap in the funnel.
    func testAPressDuringTheWaitIsReportedOnce() async throws {
        let harness = makeHarness(
            modelState: .unavailable("the speech model has not been downloaded yet", needsUserAction: true)
        )
        let gate = harness.engine.blockNextPreparation()
        try await waitUntil("the fetch is under way") { harness.coordinator.transcriptionModelState.isPreparing }

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)

        XCTAssertNotNil(harness.coordinator.speechModelNotice)
        XCTAssertEqual(
            harness.telemetry.names.filter { $0 == "dictation_blocked_by_model" }.count,
            1,
            "an impatient person is one install, not one event per press"
        )
        gate.open()
    }

    /// A model that is ready is not a wait, and a press into it reports
    /// nothing at all.
    func testAPressWithTheModelReadyReportsNothing() async throws {
        let harness = makeHarness()
        try await waitUntil("launch has read the model state") {
            harness.coordinator.transcriptionModelState.isReady
        }

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)

        XCTAssertFalse(harness.telemetry.names.contains("dictation_blocked_by_model"))
    }

    /// macOS asked and the answer was no, which is a first run that ends where
    /// it starts.
    func testADeniedMicrophoneIsReported() async throws {
        let harness = makeHarness(microphone: .notDetermined, answersMicrophoneWith: .denied)

        await harness.coordinator.requestMicrophoneAccess()

        XCTAssertTrue(harness.telemetry.names.contains("microphone_denied"))
    }

    /// A granted one is not an event. Nothing about a working app needs to
    /// leave it.
    func testAGrantedMicrophoneIsNotReported() async throws {
        let harness = makeHarness(microphone: .notDetermined)

        await harness.coordinator.requestMicrophoneAccess()

        XCTAssertFalse(harness.telemetry.names.contains("microphone_denied"))
    }
}
