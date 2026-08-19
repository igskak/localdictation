import XCTest
@testable import LocalDictation

@MainActor
final class DictationCoordinatorTranscriptionTests: XCTestCase {
    private func makeCoordinator(
        transcription: FakeTranscriptionService
    ) -> (DictationCoordinator, FakeHotkeyService, FakeAudioCaptureService) {
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: transcription
        )
        coordinator.activate()
        return (coordinator, hotkey, capture)
    }

    private func recordOneUtterance(_ hotkey: FakeHotkeyService) {
        hotkey.emit(.pressed)
        hotkey.emit(.released)
    }

    func testCompletedUtteranceIsTranscribedAndPublished() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("Rechnung", 0.9), ("bezahlt", 0.8)], profile: .germanEnglish))
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)

        try await waitUntil("transcript is published") { coordinator.transcript != nil }

        XCTAssertEqual(coordinator.transcript?.text, "Rechnung bezahlt")
        XCTAssertEqual(engine.transcribeCount, 1)
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testTheSelectedProfileIsPassedToTheEngine() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("привіт", 0.9)], profile: .ukrainianEnglish))
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)
        coordinator.languageProfile = .ukrainianEnglish

        recordOneUtterance(hotkey)
        try await waitUntil("transcript is published") { coordinator.transcript != nil }

        XCTAssertEqual(engine.requestedProfiles, [.ukrainianEnglish])
    }

    func testStateReportsTranscribingWhileInferenceRuns() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("hello", 0.9)]))
        let gate = engine.blockNextTranscription()
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("coordinator reports transcribing") { coordinator.state == .transcribing }

        XCTAssertNil(coordinator.transcript)
        gate.open()

        try await waitUntil("coordinator returns to ready") { coordinator.state == .ready }
        XCTAssertEqual(coordinator.transcript?.text, "hello")
    }

    func testDiagnosticsRecordNonContentTranscriptFacts() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(
            .fixture(words: [("one", 0.9), ("two", 0.4)], audioDuration: 2, processingDuration: 0.5)
        )
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("diagnostics are recorded") { coordinator.diagnostics.lastTranscript != nil }

        let diagnostics = try XCTUnwrap(coordinator.diagnostics.lastTranscript)
        XCTAssertEqual(diagnostics.tokenCount, 2)
        XCTAssertEqual(diagnostics.engineIdentifier, "fake")
        XCTAssertTrue(diagnostics.hasConfidenceSignal)
        XCTAssertEqual(try XCTUnwrap(diagnostics.realTimeFactor), 0.25, accuracy: 0.0001)
    }

    // MARK: - Failure

    func testTranscriptionFailureIsRecoverableAndKeepsTheAppUsable() async throws {
        let engine = FakeTranscriptionService()
        engine.setError(.engineFailure("model exploded"))
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("failure is surfaced") {
            if case .failed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(coordinator.state, .failed(.transcription("Transcription failed: model exploded")))

        coordinator.recoverFromFailure()
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testUnsupportedProfileFailsWithoutCallingTheEngine() async throws {
        let engine = FakeTranscriptionService()
        engine.markUnsupported(.russianUkrainian)
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)
        coordinator.languageProfile = .russianUkrainian

        recordOneUtterance(hotkey)
        try await waitUntil("failure is surfaced") {
            if case .failed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(engine.transcribeCount, 0)
        XCTAssertNil(coordinator.transcript)
    }

    /// Capture still has to work end to end when no engine is configured, which
    /// is exactly the Phase 1 behavior.
    func testCoordinatorWithoutAnEngineStillCompletesUtterances() async throws {
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService()
        )
        coordinator.activate()

        recordOneUtterance(hotkey)
        try await waitUntil("utterance completes") { coordinator.diagnostics.lastUtterance != nil }

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertNil(coordinator.transcript)
        XCTAssertFalse(coordinator.hasTranscriptionEngine)
    }

    // MARK: - Supersede and cancellation

    /// The acceptance criterion: a superseded request must never publish.
    func testANewRecordingSupersedesTheInFlightTranscription() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("stale", 0.9)]))
        let gate = engine.blockNextTranscription()
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("first transcription is running") { coordinator.state == .transcribing }

        // Second utterance starts while the first is still being transcribed.
        engine.setResult(.fixture(words: [("fresh", 0.9)]))
        hotkey.emit(.pressed)
        XCTAssertEqual(coordinator.state, .starting)

        // The superseded request finishes late and must be discarded.
        gate.open()
        hotkey.emit(.released)

        try await waitUntil("second transcript is published") { coordinator.transcript != nil }
        XCTAssertEqual(coordinator.transcript?.text, "fresh")
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testStartingANewRecordingClearsThePreviousTranscript() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("first", 0.9)]))
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("first transcript is published") { coordinator.transcript != nil }

        hotkey.emit(.pressed)
        XCTAssertNil(coordinator.transcript, "a stale transcript must not survive into the next utterance")
    }

    func testDeactivateCancelsAnInFlightTranscription() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("stale", 0.9)]))
        let gate = engine.blockNextTranscription()
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("transcription is running") { coordinator.state == .transcribing }

        coordinator.deactivate()
        gate.open()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(coordinator.transcript)
    }

    // MARK: - Model preparation

    func testPreparingTheModelReportsReady() async {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not installed"))
        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        await coordinator.prepareTranscriptionModel()

        XCTAssertEqual(coordinator.transcriptionModelState, .ready)
        XCTAssertEqual(engine.prepareCount, 1)
    }

    func testFailedPreparationSurfacesAnActionableMessage() async {
        let engine = FakeTranscriptionService()
        engine.failPreparation(with: .modelUnavailable("no German model"))
        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        await coordinator.prepareTranscriptionModel()

        XCTAssertEqual(
            coordinator.transcriptionModelState,
            .failed("Speech model unavailable: no German model")
        )
    }

    /// Opening the menu re-reads authorization; that must not knock a running
    /// transcription out of its state.
    func testAuthorizationRefreshDoesNotInterruptTranscription() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("hello", 0.9)]))
        let gate = engine.blockNextTranscription()
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        recordOneUtterance(hotkey)
        try await waitUntil("transcription is running") { coordinator.state == .transcribing }

        coordinator.refreshAuthorization()
        XCTAssertEqual(coordinator.state, .transcribing)

        gate.open()
        try await waitUntil("transcript is published") { coordinator.transcript != nil }
    }
}
