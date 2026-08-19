import XCTest
@testable import LocalDictation

/// The Phase 3 slice end to end, with fakes: transcript in, cleanup and risk
/// applied, review decided, audio released at the decision.
@MainActor
final class DictationCoordinatorReviewTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let capture: FakeAudioCaptureService
        let engine: FakeTranscriptionService
        let player: FakeAudioFragmentPlayer
        let glossaryStore: InMemoryGlossaryStore
    }

    private func makeHarness(
        transcript: Transcript,
        glossary: Glossary = .empty,
        profile: LanguageProfile = .german
    ) -> Harness {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript)
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let player = FakeAudioFragmentPlayer()
        let store = InMemoryGlossaryStore(glossary)
        // One second of audio at the capture sample rate, so the fixture's
        // token timings fall inside the recording a replay would slice.
        capture.setSnapshot(
            CaptureSnapshot(
                frameCount: 16_000,
                capacityFrames: 1_920_000,
                peakLevel: 0.42,
                sampleRate: AudioTargetFormat.sampleRate
            )
        )

        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: store,
            fragmentPlayer: player,
            languageProfile: profile
        )
        coordinator.activate()
        return Harness(
            coordinator: coordinator,
            hotkey: hotkey,
            capture: capture,
            engine: engine,
            player: player,
            glossaryStore: store
        )
    }

    private func record(_ harness: Harness) {
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
    }

    /// Text with nothing worth checking: no amount, no name, no removed word.
    private static let quietTranscript = Transcript.fixture(
        text: "der termin steht",
        profile: .german,
        secondsPerWord: 0.2
    )
    /// Text carrying an amount, which is exactly what the product promises to
    /// put in front of the user.
    private static let riskyTranscript = Transcript.fixture(
        text: "bitte überweise 1450 euro",
        profile: .german,
        secondsPerWord: 0.2
    )

    // MARK: - The quiet path

    func testAResultWithNothingWorthCheckingNeverInterrupts() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertEqual(result.cleanedText, "Der termin steht.")
        XCTAssertFalse(result.requiresReview)
        XCTAssertEqual(harness.coordinator.state, .ready)
    }

    /// The acceptance criterion: the recording's lifetime ends at the decision,
    /// not at the end of the interaction.
    func testAudioIsReleasedTheMomentTheDecisionIsNoReviewNeeded() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        XCTAssertFalse(
            harness.coordinator.hasRetainedAudio,
            "audio must not outlive a decision that no review is needed"
        )
        XCTAssertEqual(harness.coordinator.retainedAudioFrameCount, 0)
        XCTAssertFalse(harness.coordinator.canReplayFragments)
    }

    // MARK: - The review path

    func testAFlaggedFragmentShowsTheReviewStripAndHoldsTheAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertTrue(result.requiresReview)
        XCTAssertTrue(result.flaggedSpans.contains { $0.text == "1450" })
        XCTAssertTrue(harness.coordinator.hasRetainedAudio, "a review needs the audio it may replay")
        XCTAssertTrue(harness.coordinator.canReplayFragments)
    }

    func testCompletingAReviewReleasesTheAudioAndReturnsToReady() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        let stopsBefore = harness.player.stopCount
        harness.coordinator.acceptReview()

        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
        XCTAssertGreaterThan(harness.player.stopCount, stopsBefore, "playback must not outlive the review")
    }

    func testDismissingAReviewAlsoReleasesTheAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        harness.coordinator.dismissReview()

        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
    }

    func testStartingTheNextDictationEndsAReviewAndReleasesItsAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        harness.hotkey.emit(.pressed)

        XCTAssertEqual(harness.coordinator.state, .starting)
        XCTAssertNil(harness.coordinator.result)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
    }

    /// Opening the menu re-reads authorization, and that must not knock the
    /// user out of a review they are reading.
    func testAuthorizationRefreshDoesNotInterruptAReview() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        harness.coordinator.refreshAuthorization()

        XCTAssertEqual(harness.coordinator.state, .reviewing)
    }

    // MARK: - Raw transcript recovery

    func testTheRawTranscriptIsRecoverableThroughoutTheFlow() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertEqual(result.rawText, "bitte überweise 1450 euro")
        XCTAssertEqual(result.cleanedText, "Bitte überweise 1450 euro.")
        XCTAssertEqual(result.text(preferringRaw: true), result.rawText)
        XCTAssertEqual(result.text(preferringRaw: false), result.cleanedText)
        XCTAssertEqual(harness.coordinator.transcript?.text, result.rawText)
    }

    func testRawTranscriptPreferenceDoesNotSurviveIntoTheNextUtterance() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }
        harness.coordinator.prefersRawTranscript = true

        harness.hotkey.emit(.pressed)
        XCTAssertFalse(harness.coordinator.prefersRawTranscript)
    }

    // MARK: - Replay

    func testAFlaggedFragmentIsReplayedFromMemory() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        let span = try XCTUnwrap(harness.coordinator.result?.flaggedSpans.first { $0.text == "1450" })
        harness.coordinator.replay(span)

        XCTAssertEqual(harness.player.playCount, 1)
        XCTAssertGreaterThan(harness.player.lastFrameCount, 0)
        XCTAssertEqual(harness.player.playedFragments.first?.sampleRate, AudioTargetFormat.sampleRate)
    }

    /// Replay is an affordance of the review step, not a way to listen back to
    /// a recording the app has otherwise finished with.
    func testOnlyAFlaggedSpanCanBeReplayed() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        let result = try XCTUnwrap(harness.coordinator.result)
        let informational = try XCTUnwrap(
            result.spans.first { span in !result.flaggedSpans.contains(span) }
        )
        harness.coordinator.replay(informational)

        XCTAssertEqual(harness.player.playCount, 0)
    }

    func testNothingCanBeReplayedOnceTheAudioIsReleased() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("review is requested") { harness.coordinator.state == .reviewing }

        let span = try XCTUnwrap(harness.coordinator.result?.flaggedSpans.first)
        harness.coordinator.acceptReview()
        harness.coordinator.replay(span)

        XCTAssertEqual(harness.player.playCount, 0)
    }

    // MARK: - Glossary

    func testGlossaryIsLoadedAtActivationAndFeedsTheRiskEngine() async throws {
        var glossary = Glossary()
        glossary.add("Müller", language: .german)
        let harness = makeHarness(
            transcript: .fixture(text: "an Miller überweisen", profile: .german, secondsPerWord: 0.2),
            glossary: glossary
        )

        XCTAssertEqual(harness.coordinator.glossary.entries.count, 1)

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        let spans = try XCTUnwrap(harness.coordinator.result?.flaggedSpans)
        XCTAssertTrue(spans.contains { $0.reason == .glossaryNearMiss(term: "Müller") })
    }

    func testAddingATermPersistsItImmediately() {
        let harness = makeHarness(transcript: Self.quietTranscript)

        XCTAssertTrue(harness.coordinator.addGlossaryTerm("  Schneider ", language: .german))
        XCTAssertFalse(harness.coordinator.addGlossaryTerm("schneider", language: .german))

        XCTAssertEqual(harness.glossaryStore.current.entries.map(\.term), ["Schneider"])
        XCTAssertEqual(harness.glossaryStore.saveCount, 1)
    }

    func testRemovingATermPersistsToo() {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.coordinator.addGlossaryTerm("Schneider", language: .german)
        let id = try! XCTUnwrap(harness.coordinator.glossary.entries.first?.id)

        harness.coordinator.removeGlossaryTerm(id: id)

        XCTAssertTrue(harness.glossaryStore.current.entries.isEmpty)
    }

    func testAFailingStoreLeavesTheAppUsable() {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.glossaryStore.failSave(with: .unwritable("disk is full"))

        harness.coordinator.addGlossaryTerm("Schneider", language: .german)

        XCTAssertEqual(harness.coordinator.glossary.entries.count, 1, "the term is still usable this session")
        XCTAssertEqual(
            harness.coordinator.glossaryErrorDescription,
            "The dictionary could not be saved: disk is full"
        )
    }

    /// With no engine configured, nothing downstream can use the samples, so
    /// they must not sit in memory waiting for the next utterance.
    func testAudioIsReleasedWhenNoTranscriptionStarts() async throws {
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService()
        )
        coordinator.activate()

        hotkey.emit(.pressed)
        hotkey.emit(.released)
        try await waitUntil("utterance completes") { coordinator.diagnostics.lastUtterance != nil }

        XCTAssertFalse(coordinator.hasRetainedAudio)
    }

    func testAudioIsReleasedWhenTheProfileIsUnsupported() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.engine.markUnsupported(.german)

        record(harness)
        try await waitUntil("failure is surfaced") {
            if case .failed = harness.coordinator.state { return true }
            return false
        }

        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
    }

    // MARK: - Failure

    func testAFailedTranscriptionReleasesTheAudioAndKeepsTheAppUsable() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.engine.setError(.engineFailure("model exploded"))

        record(harness)
        try await waitUntil("failure is surfaced") {
            if case .failed = harness.coordinator.state { return true }
            return false
        }

        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
        harness.coordinator.recoverFromFailure()
        XCTAssertEqual(harness.coordinator.state, .ready)
    }

    // MARK: - Diagnostics

    func testDiagnosticsRecordTheStagesWithoutRecordingAnyText() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("risk diagnostics are recorded") { harness.coordinator.diagnostics.lastRisk != nil }

        let risk = try XCTUnwrap(harness.coordinator.diagnostics.lastRisk)
        XCTAssertTrue(risk.requiresReview)
        XCTAssertGreaterThan(risk.flaggedSpanCount, 0)
        XCTAssertTrue(risk.spanCategories.contains("number"))

        // The diagnostics type has no field that could hold recognized text.
        let mirror = Mirror(reflecting: risk)
        for child in mirror.children {
            if let value = child.value as? String {
                XCTAssertFalse(harness.coordinator.result!.rawText.contains(value))
            }
        }
    }
}
