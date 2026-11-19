import XCTest
@testable import Witness

/// A press that comes back with nothing.
///
/// Before this, the app said nothing at all about it: insertion is skipped for
/// empty text, the review policy prices it as quiet, and the state returns to
/// `.ready`. `docs/PHASE_4_COMPATIBILITY.md` records two real utterances of
/// 8.8 s and 10.1 s that did exactly that, and reads the result the way any
/// user would — as the app not working.
@MainActor
final class SilentDictationTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let capture: FakeAudioCaptureService
        let engine: FakeTranscriptionService
    }

    private func makeHarness(
        transcript: Transcript,
        snapshot: CaptureSnapshot = .heardSpeech,
        minimumAudioDuration: TimeInterval = 0
    ) -> Harness {
        let engine = FakeTranscriptionService()
        engine.minimumAudioDuration = minimumAudioDuration
        engine.setResult(transcript)
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        capture.setSnapshot(snapshot)

        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            languageProfile: .german
        )
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, capture: capture, engine: engine)
    }

    private func record(_ harness: Harness) {
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
    }

    // MARK: - Empty and short captures

    func testShortPressIsAnsweredWithoutCallingEngineAndNextPressWorks() async throws {
        for frames in [1, 4_799] {
            let harness = makeHarness(
                transcript: .fixture(text: "next recording", profile: .german),
                snapshot: CaptureSnapshot(frameCount: frames, peakLevel: 0.1, sampleRate: 16_000),
                minimumAudioDuration: 0.3
            )
            record(harness)
            try await waitUntil("short capture is answered") { harness.coordinator.silentResult != nil }
            XCTAssertEqual(harness.coordinator.silentResult, .tooShort(duration: Double(frames) / 16_000))
            XCTAssertEqual(harness.engine.transcribeCount, 0)
            XCTAssertEqual(harness.coordinator.state, .ready)
            XCTAssertNil(harness.coordinator.diagnostics.lastErrorDescription)
            XCTAssertFalse(harness.coordinator.hasRetainedAudio)

            harness.capture.setSnapshot(.heardSpeech)
            record(harness)
            try await waitUntil("next capture is transcribed") { harness.coordinator.result != nil }
            XCTAssertEqual(harness.engine.transcribeCount, 1)
            XCTAssertNil(harness.coordinator.silentResult)
            harness.coordinator.deactivate()
        }
    }

    func testCaptureAtEngineMinimumIsTranscribed() async throws {
        let harness = makeHarness(
            transcript: .fixture(text: "yes", profile: .german),
            snapshot: CaptureSnapshot(frameCount: 4_800, peakLevel: 0.1, sampleRate: 16_000),
            minimumAudioDuration: 0.3
        )
        record(harness)
        try await waitUntil("minimum length is accepted") { harness.coordinator.result != nil }
        XCTAssertEqual(harness.engine.transcribeCount, 1)
        XCTAssertNil(harness.coordinator.silentResult)
    }

    func testShortCaptureDoesNotBlameTheMicrophoneOrLanguageSelection() {
        let presentation = StatusPresentation(
            state: .ready, binding: .optionSpace, silentResult: .tooShort(duration: 0.1)
        )
        XCTAssertEqual(presentation.title, L10n.string("Recording was too short"))
        XCTAssertEqual(presentation.detail, L10n.string(
            "Recording ended before enough audio was captured. Try recording a little longer."
        ))
    }

    func testSpeechThatRecognizesToNothingSaysSo() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"))

        record(harness)
        try await waitUntil("the app prices the empty result") { harness.coordinator.silentResult != nil }

        guard case let .nothingRecognized(_, profileLabel) = try XCTUnwrap(harness.coordinator.silentResult) else {
            return XCTFail("Speech was heard, so this is the engine's answer rather than the microphone's")
        }
        XCTAssertEqual(profileLabel, LanguageProfile.german.displayName)
        XCTAssertEqual(harness.coordinator.state, .ready)
    }

    func testAudioThatNeverReachedSpeechLevelBlamesTheMicrophoneInstead() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"), snapshot: .heardNothing)

        record(harness)
        try await waitUntil("the app prices the empty result") { harness.coordinator.silentResult != nil }

        guard case let .nothingHeard(_, _, device) = try XCTUnwrap(harness.coordinator.silentResult) else {
            return XCTFail("The detector never saw speech, so the microphone is what the user has to check")
        }
        XCTAssertEqual(device, "Fake Input")
    }

    func testAPressThatCapturedNoSamplesAtAllIsStillAnswered() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"), snapshot: .capturedNothing)

        record(harness)
        try await waitUntil("the app prices the empty capture") { harness.coordinator.silentResult != nil }

        guard case .nothingHeard = try XCTUnwrap(harness.coordinator.silentResult) else {
            return XCTFail("No samples means nothing was heard")
        }
        // Nothing was handed to the engine, so it was never asked.
        XCTAssertEqual(harness.engine.transcribeCount, 0)
    }

    // MARK: - What it must never do

    func testAResultWithTextInItSaysNothing() async throws {
        let harness = makeHarness(transcript: .fixture(text: "der termin steht", profile: .german))

        record(harness)
        try await waitUntil("the result arrives") { harness.coordinator.result != nil }

        XCTAssertNil(harness.coordinator.silentResult)
    }

    func testTheNoticeDoesNotSurviveIntoTheNextDictation() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"))

        record(harness)
        try await waitUntil("the notice appears") { harness.coordinator.silentResult != nil }

        harness.engine.setResult(.fixture(text: "zweiter versuch", profile: .german))
        harness.hotkey.emit(.pressed)

        XCTAssertNil(harness.coordinator.silentResult, "A notice about the last press describes the wrong utterance")
    }

    func testTheNoticeCanBePutOutWithoutWaitingForTheNextPress() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"))

        record(harness)
        try await waitUntil("the notice appears") { harness.coordinator.silentResult != nil }

        harness.coordinator.dismissSilentResult()

        XCTAssertNil(harness.coordinator.silentResult)
    }

    func testATranscriptionFailureKeepsItsOwnSentence() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"))
        harness.engine.setError(.engineFailure("model exploded"))

        record(harness)
        try await waitUntil("the failure lands") {
            if case .failed = harness.coordinator.state { return true }
            return false
        }

        XCTAssertNil(
            harness.coordinator.silentResult,
            "Two explanations for one press is one more than the user can act on"
        )
    }

    // MARK: - What the user reads

    func testTheIdleStateCarriesTheNoticeRatherThanSayingReady() {
        let presentation = StatusPresentation(
            state: .ready,
            binding: .optionSpace,
            silentResult: .nothingRecognized(duration: 8.8, profileLabel: "German")
        )

        XCTAssertEqual(presentation.title, "Nothing was recognized")
        XCTAssertTrue(presentation.detail.contains("German"))
        XCTAssertEqual(presentation.tint, .warning)
    }

    func testAMicrophoneThatHeardNothingNamesTheInputDevice() {
        let presentation = StatusPresentation(
            state: .ready,
            binding: .optionSpace,
            silentResult: .nothingHeard(duration: 9.1, peakLevel: 0.001, inputDeviceName: "Studio Display Microphone")
        )

        XCTAssertEqual(presentation.systemImage, "mic.slash")
        XCTAssertTrue(presentation.detail.contains("Studio Display Microphone"))
    }

    func testAMarkedResultIsNeverHiddenBehindTheNotice() {
        let presentation = StatusPresentation(
            state: .ready,
            binding: .optionSpace,
            attentionIsPending: true,
            silentResult: .nothingRecognized(duration: 1, profileLabel: "German")
        )

        XCTAssertEqual(presentation.title, "Worth a look")
    }

    func testTheNoticeOnlyChangesTheIdleState() {
        let presentation = StatusPresentation(
            state: .recording,
            binding: .optionSpace,
            silentResult: .nothingRecognized(duration: 1, profileLabel: "German")
        )

        XCTAssertEqual(presentation.title, "Recording")
    }

    func testTheLogLabelCarriesNoContent() {
        let labels = [
            SilentResult.nothingHeard(duration: 9.1, peakLevel: 0.002, inputDeviceName: "Fake Input").logLabel,
            SilentResult.nothingRecognized(duration: 8.8, profileLabel: "German").logLabel,
        ]

        for label in labels {
            XCTAssertTrue(label.hasPrefix("silent:"))
        }
    }
}

private extension CaptureSnapshot {
    /// The detector saw speech: `speechStart` is what the coordinator reads to
    /// tell the microphone's problem from the engine's.
    static let heardSpeech = CaptureSnapshot(
        frameCount: 16_000,
        capacityFrames: 1_920_000,
        peakLevel: 0.42,
        voiceActivity: VoiceActivityObservation(
            state: .endedBySilence,
            speechStart: 0.3,
            trailingSilence: 1,
            elapsed: 1,
            lastWindowRMS: 0.001
        ),
        sampleRate: AudioTargetFormat.sampleRate
    )

    /// The microphone was open and nothing in it ever reached speech level.
    static let heardNothing = CaptureSnapshot(
        frameCount: 16_000,
        capacityFrames: 1_920_000,
        peakLevel: 0.004,
        voiceActivity: .initial,
        sampleRate: AudioTargetFormat.sampleRate
    )

    /// The capture returned no samples at all.
    static let capturedNothing = CaptureSnapshot(
        frameCount: 0,
        capacityFrames: 1_920_000,
        peakLevel: 0,
        voiceActivity: .initial,
        sampleRate: AudioTargetFormat.sampleRate
    )
}
