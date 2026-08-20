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
        profile: LanguageProfile = .german,
        // Defaults to an engine with no dictionaries, so most tests here see
        // exactly the deterministic signals they were written against. The
        // tests that exercise `MalformedWordSignal` pass a lexicon that answers
        // "unknown" to everything, which leaves its shape rule as the only
        // thing deciding — and keeps the assertion independent of which
        // spelling files this Mac has installed.
        riskEngine: RiskEngine = .standard()
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
            riskEngine: riskEngine,
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

    func testAResultWithNothingWorthCheckingSaysNothing() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertEqual(result.cleanedText, "Der termin steht.")
        XCTAssertFalse(result.deservesAttention)
        XCTAssertFalse(harness.coordinator.attentionIsPending)
        XCTAssertFalse(harness.coordinator.isShowingReview)
    }

    /// The acceptance criterion: the recording's lifetime ends at the decision,
    /// not at the end of the interaction.
    func testAudioIsReleasedTheMomentTheResultTurnsOutToBeQuiet() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        XCTAssertFalse(
            harness.coordinator.hasRetainedAudio,
            "audio must not outlive a decision that there is nothing worth checking"
        )
        XCTAssertEqual(harness.coordinator.retainedAudioFrameCount, 0)
        XCTAssertFalse(harness.coordinator.canReplayFragments)
    }

    // MARK: - The review path

    func testAFlaggedFragmentLightsTheIndicatorAndHoldsTheAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertTrue(result.deservesAttention)
        XCTAssertTrue(result.flaggedSpans.contains { $0.text == "1450" })
        XCTAssertTrue(harness.coordinator.hasRetainedAudio, "a review needs the audio it may replay")
        XCTAssertTrue(harness.coordinator.canReplayFragments)
    }

    func testOpeningTheReviewPutsTheIndicatorOutAndKeepsTheAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

        harness.coordinator.openReview()

        XCTAssertTrue(harness.coordinator.isShowingReview)
        XCTAssertFalse(harness.coordinator.attentionIsPending, "a lit triangle behind an open review says nothing")
        XCTAssertTrue(harness.coordinator.hasRetainedAudio, "replay is the reason the review exists")
    }

    func testClosingTheReviewReleasesTheAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }
        harness.coordinator.openReview()

        let stopsBefore = harness.player.stopCount
        harness.coordinator.closeReview()

        XCTAssertFalse(harness.coordinator.isShowingReview)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
        XCTAssertGreaterThan(harness.player.stopCount, stopsBefore, "playback must not outlive the review")
    }

    /// Declining the offer without opening it must release the recording too.
    /// The review was the only thing that would have used the samples.
    func testDismissingTheIndicatorUnopenedReleasesTheAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

        harness.coordinator.dismissAttention()

        XCTAssertFalse(harness.coordinator.attentionIsPending)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
    }

    func testStartingTheNextDictationEndsAReviewAndReleasesItsAudio() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }
        harness.coordinator.openReview()

        harness.hotkey.emit(.pressed)

        XCTAssertEqual(harness.coordinator.state, .starting)
        XCTAssertNil(harness.coordinator.result)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
        XCTAssertFalse(harness.coordinator.isShowingReview)
        XCTAssertFalse(harness.coordinator.attentionIsPending, "an indicator that outlives its utterance means nothing")
    }

    /// Opening the menu re-reads authorization, and that must not knock the
    /// user out of a review they are reading.
    func testAuthorizationRefreshDoesNotCloseAReview() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }
        harness.coordinator.openReview()

        harness.coordinator.refreshAuthorization()

        XCTAssertTrue(harness.coordinator.isShowingReview)
    }

    // MARK: - The complaint this phase came from

    /// One utterance carrying both halves of the report that started Phase 5:
    /// a messenger's name that came out right, and a word the engine mangled.
    ///
    /// Before, the app marked the first and missed the second — it pointed at
    /// the word that was correct and said nothing about the one that was not,
    /// and it did it by holding the text back until someone answered a panel.
    /// All three of those are asserted here, because a fix to any one of them
    /// alone would leave the complaint standing.
    func testACorrectNameIsNotFlaggedAndAMangledWordIs() async throws {
        var glossary = Glossary()
        glossary.add("Флок", language: .russian)
        let harness = makeHarness(
            transcript: .fixture(
                text: "вчера ррверка прошла и обсуждение перенесли во Флок",
                profile: .russian,
                secondsPerWord: 0.2
            ),
            glossary: glossary,
            profile: .russian,
            riskEngine: .standard(lexicon: ShapeOnlyLexicon())
        )

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertTrue(
            result.flaggedSpans.contains { $0.text == "ррверка" },
            "the word the engine mangled is what the user is told to check"
        )
        XCTAssertFalse(
            result.flaggedSpans.contains { $0.text == "Флок" },
            "a name the user put in their own dictionary is not a risk"
        )
        XCTAssertFalse(
            result.highlightedSpans.contains { $0.text == "Флок" },
            "and it is not worth an underline either"
        )
    }

    /// The same sentence without the dictionary entry. The name is still marked
    /// — a capitalization heuristic cannot know better — but it is marked
    /// quietly, and it is not the reason anyone is told to look.
    func testAnUnknownNameIsShownWithoutBeingAnnounced() async throws {
        let harness = makeHarness(
            transcript: .fixture(
                text: "обсуждение перенесли во Флок",
                profile: .russian,
                secondsPerWord: 0.2
            ),
            profile: .russian,
            riskEngine: .standard(lexicon: ShapeOnlyLexicon())
        )

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        let result = try XCTUnwrap(harness.coordinator.result)
        XCTAssertTrue(result.highlightedSpans.contains { $0.text == "Флок" })
        XCTAssertFalse(result.deservesAttention, "a capitalized word is not worth a triangle")
        XCTAssertFalse(harness.coordinator.attentionIsPending)
    }

    // MARK: - Raw transcript recovery

    func testTheRawTranscriptIsRecoverableThroughoutTheFlow() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

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
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }
        harness.coordinator.prefersRawTranscript = true

        harness.hotkey.emit(.pressed)
        XCTAssertFalse(harness.coordinator.prefersRawTranscript)
    }

    // MARK: - Replay

    func testAFlaggedFragmentIsReplayedFromMemory() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

        let span = try XCTUnwrap(harness.coordinator.result?.flaggedSpans.first { $0.text == "1450" })
        harness.coordinator.replay(span)

        XCTAssertEqual(harness.player.playCount, 1)
        XCTAssertGreaterThan(harness.player.lastFrameCount, 0)
        XCTAssertEqual(harness.player.playedFragments.first?.sampleRate, AudioTargetFormat.sampleRate)
    }

    /// Replay is an affordance of the review step, not a way to listen back to
    /// a recording the app has otherwise finished with — so a span the review
    /// never draws cannot be played.
    func testOnlyASpanTheReviewShowsCanBeReplayed() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

        let result = try XCTUnwrap(harness.coordinator.result)
        let hidden = try XCTUnwrap(
            result.spans.first { span in !result.highlightedSpans.contains(span) }
        )
        harness.coordinator.replay(hidden)

        XCTAssertEqual(harness.player.playCount, 0)
    }

    func testNothingCanBeReplayedOnceTheAudioIsReleased() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }

        let span = try XCTUnwrap(harness.coordinator.result?.flaggedSpans.first)
        harness.coordinator.openReview()
        harness.coordinator.closeReview()
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
        XCTAssertTrue(risk.deservesAttention)
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
