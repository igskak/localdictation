import XCTest
@testable import Witness

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
        engine.setModelState(.unavailable("not installed", needsUserAction: true))
        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        await coordinator.prepareTranscriptionModel()

        XCTAssertEqual(coordinator.transcriptionModelState, .ready)
        XCTAssertEqual(engine.prepareCount, 1)
    }

    /// Weights already on disk cost seconds to load and no network at all, so
    /// the app pays that at launch rather than making the user pay it at the
    /// moment they want to dictate.
    func testLaunchLoadsWeightsThatAreAlreadyOnDisk() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("installed but not loaded", needsUserAction: false))

        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        try await waitUntil("model is loaded at launch") { coordinator.transcriptionModelState.isReady }
        XCTAssertEqual(engine.prepareCount, 1)
    }

    /// The reversal recorded in `docs/REFINEMENTS.md`. The download used to be
    /// bound to a button in a menu bar window, which is a step nobody had been
    /// told about between a fresh install and a product that does nothing at
    /// all without it. Launch now fetches the weights itself.
    func testLaunchDownloadsTheModelItself() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not downloaded yet", needsUserAction: true))

        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        try await waitUntil("the model is fetched at launch") { coordinator.transcriptionModelState.isReady }
        XCTAssertEqual(engine.prepareCount, 1)
    }

    /// A launch that cannot even locate its storage is a broken installation
    /// rather than a missing download, and retrying it in a loop nobody asked
    /// for would say nothing new.
    func testLaunchDoesNotRetryAFailedEngine() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.failed("Could not locate Application Support"))

        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        try await waitUntil("launch has read the model state") {
            coordinator.transcriptionModelState == .failed("Could not locate Application Support")
        }
        XCTAssertEqual(engine.prepareCount, 0)
    }

    // MARK: - The press that arrives before the model does

    /// The whole point of the notice: nothing is recorded, the state machine is
    /// untouched, and the user is told why rather than left with a key that did
    /// nothing.
    func testAPressDuringTheDownloadRecordsNothingAndIsAnswered() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not downloaded yet", needsUserAction: true))
        let gate = engine.blockNextPreparation()
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)

        try await waitUntil("the launch download is running") { coordinator.transcriptionModelState.isPreparing }

        recordOneUtterance(hotkey)

        XCTAssertEqual(capture.startCount, 0, "a press that cannot be transcribed must not open the microphone")
        XCTAssertEqual(coordinator.state, .ready)
        guard case .preparing = try XCTUnwrap(coordinator.speechModelNotice) else {
            return XCTFail("the press should be answered with the wait it ran into")
        }

        gate.open()
        try await waitUntil("the model finishes") { coordinator.transcriptionModelState.isReady }
    }

    /// The other half of the promise the notice makes: "Witness will say so".
    func testTheEndOfTheWaitIsAnnouncedToWhoeverPressedDuringIt() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not downloaded yet", needsUserAction: true))
        let gate = engine.blockNextPreparation()
        let (coordinator, hotkey, _) = makeCoordinator(transcription: engine)

        try await waitUntil("the launch download is running") { coordinator.transcriptionModelState.isPreparing }
        recordOneUtterance(hotkey)

        gate.open()
        try await waitUntil("the ready notice arrives") {
            coordinator.speechModelNotice == .ready(hotkey: coordinator.binding.displayString)
        }
    }

    /// Nobody pressed, so nobody is waiting, and a panel opening over somebody's
    /// document to report that nothing is wrong is noise.
    func testAModelThatArrivesUnaskedSaysNothing() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not downloaded yet", needsUserAction: true))
        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        try await waitUntil("the model is ready") { coordinator.transcriptionModelState.isReady }
        XCTAssertNil(coordinator.speechModelNotice)
    }

    /// A press when the weights are missing and nothing is fetching them —
    /// a launch with no network, say — starts the fetch rather than sending
    /// the user to look for a button.
    func testAPressWithNothingInFlightStartsTheFetch() async throws {
        let engine = FakeTranscriptionService()
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)
        try await waitUntil("launch has read the model state") { coordinator.transcriptionModelState.isReady }

        engine.setModelState(.unavailable("the download did not finish", needsUserAction: true))
        await coordinator.refreshTranscriptionModelState()

        recordOneUtterance(hotkey)

        XCTAssertEqual(capture.startCount, 0)
        guard case .starting = try XCTUnwrap(coordinator.speechModelNotice) else {
            return XCTFail("the press should say the fetch has started")
        }
        try await waitUntil("the fetch runs") { engine.prepareCount == 1 }
    }

    /// The same for a fetch that failed. The sentence carries the engine's own
    /// reason, because "no space left on the device" and "offline" have
    /// different answers.
    func testAPressAfterAFailedFetchRetriesAndSaysWhy() async throws {
        let engine = FakeTranscriptionService()
        engine.failPreparation(with: .modelUnavailable("no space left"))
        engine.setModelState(.failed("Speech model unavailable: no space left"))
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)

        try await waitUntil("launch has read the failure") {
            coordinator.transcriptionModelState == .failed("Speech model unavailable: no space left")
        }

        recordOneUtterance(hotkey)

        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(
            coordinator.speechModelNotice,
            .failed("Speech model unavailable: no space left")
        )
        try await waitUntil("the retry runs") { engine.prepareCount == 1 }
    }

    /// The exception, and the older decision it preserves: reading installed
    /// weights takes seconds, the recording is held and transcribed the moment
    /// the load ends, and refusing that press would throw away words the user
    /// had already said.
    func testAPressDuringAWarmLoadIsStillRecorded() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("held", 0.9)]))
        engine.setModelState(.unavailable("installed but not loaded", needsUserAction: false))
        let gate = engine.blockNextPreparation()
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)

        try await waitUntil("the launch load is running") {
            coordinator.transcriptionModelState == .preparing(ModelPreparation(phase: .loading))
        }

        recordOneUtterance(hotkey)
        try await waitUntil("the recording was made") { capture.startCount == 1 }
        XCTAssertNil(coordinator.speechModelNotice, "a nine-second load is not worth a notice")

        gate.open()
        try await waitUntil("the held recording is transcribed") { coordinator.transcript != nil }
        XCTAssertEqual(coordinator.transcript?.text, "held")
    }

    /// A build with no engine at all never offered recognition, and refusing
    /// its presses would take away the capture it does do.
    func testAPressIsNeverRefusedWithoutAnEngine() async throws {
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService()
        )
        coordinator.activate()

        XCTAssertFalse(coordinator.isAwaitingSpeechModel)
        recordOneUtterance(hotkey)
        try await waitUntil("utterance completes") { coordinator.diagnostics.lastUtterance != nil }
        XCTAssertNil(coordinator.speechModelNotice)
    }

    /// The regression behind "I pressed Prepare and nothing happened": while a
    /// load runs the menu must show a spinner, not the button again. Offering
    /// the button back is what led to repeated presses and competing loads.
    func testModelReportsPreparingWhileTheLoadIsInFlight() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not installed", needsUserAction: true))
        let gate = engine.blockNextPreparation()
        let (coordinator, _, _) = makeCoordinator(transcription: engine)

        let preparation = Task { await coordinator.prepareTranscriptionModel() }
        try await waitUntil("preparation is in flight") {
            coordinator.transcriptionModelState.isPreparing
        }
        XCTAssertFalse(coordinator.transcriptionModelState.isReady)

        gate.open()
        await preparation.value

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
