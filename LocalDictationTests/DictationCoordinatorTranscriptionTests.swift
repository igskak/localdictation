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

    // MARK: - Language head start

    /// Whisper has to know the language before it can decode, and finding out
    /// costs a full encoder pass. These cover the half of the optimization that
    /// is testable without a model: that the opening of the recording reaches
    /// the engine while the user is still speaking, and only when it is worth
    /// sending.

    private func startRecording(
        _ coordinator: DictationCoordinator,
        _ hotkey: FakeHotkeyService
    ) async throws {
        hotkey.emit(.pressed)
        try await waitUntil("capture is running") { coordinator.state == .recording }
    }

    func testTheOpeningOfAMixedProfileRecordingIsHandedToTheEngineWhileItRuns() async throws {
        let engine = FakeTranscriptionService()
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)
        coordinator.languageProfile = .germanEnglish
        try await startRecording(coordinator, hotkey)

        capture.setSnapshot(CaptureSnapshot(frameCount: LanguageHeadStart.frames, capacityFrames: 1_920_000))
        coordinator.pollDiagnostics()

        try await waitUntil("the engine is offered a head start") { engine.languageHeadStarts.count == 1 }
        XCTAssertEqual(engine.languageHeadStarts.first?.frames, LanguageHeadStart.frames)
        XCTAssertEqual(engine.languageHeadStarts.first?.profile, .germanEnglish)

        // One per utterance. The poll runs ten times a second and every extra
        // call would be another encoder pass for an answer already in flight.
        coordinator.pollDiagnostics()
        coordinator.pollDiagnostics()
        XCTAssertEqual(engine.languageHeadStarts.count, 1)
    }

    func testAShortRecordingIsNeverHandedToTheEngineEarly() async throws {
        let engine = FakeTranscriptionService()
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)
        coordinator.languageProfile = .germanEnglish
        try await startRecording(coordinator, hotkey)

        capture.setSnapshot(CaptureSnapshot(frameCount: LanguageHeadStart.frames - 1, capacityFrames: 1_920_000))
        coordinator.pollDiagnostics()

        XCTAssertTrue(engine.languageHeadStarts.isEmpty, "Too little speech to detect anything from")
    }

    /// A single selected language never reaches the detector at all, so there
    /// is nothing to run ahead of and no reason to spend a pass on it.
    func testASingleLanguageProfileIsNeverOfferedAHeadStart() async throws {
        let engine = FakeTranscriptionService()
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)
        coordinator.languageProfile = LanguageProfile(.english)
        try await startRecording(coordinator, hotkey)

        capture.setSnapshot(CaptureSnapshot(frameCount: LanguageHeadStart.frames * 4, capacityFrames: 1_920_000))
        coordinator.pollDiagnostics()

        XCTAssertTrue(engine.languageHeadStarts.isEmpty)
    }

    /// The coordinator holds the engine as `any TranscriptionService`, and the
    /// head start reaches it through that. It got there through an empty
    /// default in a protocol extension once, which compiled, passed every test,
    /// and did nothing. The requirement has no default now, so this asserts the
    /// remaining half: that a call through the existential lands on the engine.
    func testTheHeadStartReachesTheEngineThroughTheProtocol() async throws {
        let engine = FakeTranscriptionService()
        let service: any TranscriptionService = engine

        await service.beginLanguageDetection(
            prefix: [Float](repeating: 0, count: LanguageHeadStart.frames),
            profile: .germanEnglish
        )

        XCTAssertEqual(engine.languageHeadStarts.count, 1)
    }

    func testEachPressGetsItsOwnHeadStart() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("hallo", 0.9)], profile: .germanEnglish))
        let (coordinator, hotkey, capture) = makeCoordinator(transcription: engine)
        coordinator.languageProfile = .germanEnglish
        capture.setSnapshot(CaptureSnapshot(frameCount: LanguageHeadStart.frames, capacityFrames: 1_920_000))

        try await startRecording(coordinator, hotkey)
        coordinator.pollDiagnostics()
        try await waitUntil("the first head start is offered") { engine.languageHeadStarts.count == 1 }
        hotkey.emit(.released)
        try await waitUntil("the first transcript is published") { coordinator.transcript != nil }

        try await startRecording(coordinator, hotkey)
        coordinator.pollDiagnostics()
        try await waitUntil("the second head start is offered") { engine.languageHeadStarts.count == 2 }
    }
}
