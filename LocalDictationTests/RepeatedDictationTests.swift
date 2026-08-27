import XCTest
@testable import LocalDictation

/// What holding a recording costs over a working session.
///
/// `docs/PHASE_3_VERIFICATION.md` has carried "ten minutes of repeated short
/// recordings without memory growth" as an unverified item since Phase 3 added
/// a retained audio buffer. The soak itself still needs a person and a
/// microphone. What a test can settle is the structural half of it, which is
/// where a leak would actually come from: whether the app ever holds more than
/// one utterance at a time, and whether it lets go on the paths that promise to.
@MainActor
final class RepeatedDictationTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let engine: FakeTranscriptionService
    }

    private func makeHarness(transcript: Transcript) -> Harness {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript)
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        capture.setSnapshot(
            CaptureSnapshot(
                frameCount: 16_000,
                capacityFrames: 1_920_000,
                peakLevel: 0.42,
                voiceActivity: VoiceActivityObservation(
                    state: .endedBySilence,
                    speechStart: 0.2,
                    trailingSilence: 1,
                    elapsed: 1,
                    lastWindowRMS: 0.001
                ),
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
            languageProfile: .german
        )
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, engine: engine)
    }

    /// Nothing worth checking: the policy prices it as quiet and the recording's
    /// job is over the moment the text is ready.
    private static let quiet = Transcript.fixture(text: "der termin steht", profile: .german, secondsPerWord: 0.2)
    /// Carries an amount, so the indicator lights and the samples are kept for
    /// a replay the user may never ask for.
    private static let flagged = Transcript.fixture(
        text: "bitte überweise 1450 euro",
        profile: .german,
        secondsPerWord: 0.2
    )

    private func dictate(_ harness: Harness) async throws {
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("the result arrives") { harness.coordinator.result != nil }
        try await waitUntil("the app settles") { harness.coordinator.state == .ready }
    }

    func testSixtyQuietDictationsLeaveNoAudioBehind() async throws {
        let harness = makeHarness(transcript: Self.quiet)

        for index in 1...60 {
            try await dictate(harness)
            XCTAssertFalse(
                harness.coordinator.hasRetainedAudio,
                "A quiet result releases the recording immediately; it was still held after \(index)"
            )
        }
    }

    /// The expensive path: every result is worth pointing at, so every
    /// recording is kept for a review the user never opens. The app must still
    /// hold exactly one of them.
    func testSixtyFlaggedDictationsNeverHoldMoreThanOneRecording() async throws {
        let harness = makeHarness(transcript: Self.flagged)

        var frameCounts: Set<Int> = []
        for _ in 1...60 {
            try await dictate(harness)
            XCTAssertTrue(harness.coordinator.attentionIsPending)
            frameCounts.insert(harness.coordinator.retainedAudioFrameCount)
        }

        XCTAssertEqual(
            frameCounts.count,
            1,
            "Holding one utterance is the design; holding a growing number of them is the leak"
        )
        XCTAssertEqual(harness.coordinator.retainedAudioFrameCount, 16_000)
    }

    /// The indicator is per-utterance. One left lit from the dictation before
    /// last would be pointing at text the user has already replaced.
    func testAnIndicatorNeverSurvivesTheDictationAfterIt() async throws {
        let harness = makeHarness(transcript: Self.flagged)
        try await dictate(harness)
        XCTAssertTrue(harness.coordinator.attentionIsPending)

        harness.engine.setResult(Self.quiet)
        try await dictate(harness)

        XCTAssertFalse(harness.coordinator.attentionIsPending)
        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
    }

    /// Deactivating is what the app does when it is quit. Anything it holds
    /// after that is something the previous run could not let go of.
    func testDeactivatingReleasesEverythingItWasHolding() async throws {
        let harness = makeHarness(transcript: Self.flagged)
        try await dictate(harness)
        XCTAssertTrue(harness.coordinator.hasRetainedAudio)

        harness.coordinator.deactivate()

        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
        XCTAssertNil(harness.coordinator.registeredHotkey)
        XCTAssertFalse(harness.coordinator.isWatchingForAccessibilityTrust)
    }
}
