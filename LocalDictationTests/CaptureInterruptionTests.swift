import XCTest
@testable import Witness

/// What an input device changing mid-sentence costs.
///
/// AirPods connecting, a dock being plugged in, a headset going to sleep: all
/// of them raise `AVAudioEngineConfigurationChange` while the user is speaking.
/// The recording used to end in `.failed` with the captured audio discarded,
/// which is the app taking back words that had already been said —
/// `docs/PHASE_6.md` spends a section refusing to do exactly that for a trial
/// that runs out, and this is the same rule.
@MainActor
final class CaptureInterruptionTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let capture: FakeAudioCaptureService
        let insertion: FakeTextInsertionService
    }

    private func makeHarness(transcript: Transcript) -> Harness {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript)
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let insertion = FakeTextInsertionService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            accessibilityService: FakeAccessibilityPermissionService(authorization: .trusted),
            insertionService: insertion,
            languageProfile: .german
        )
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, capture: capture, insertion: insertion)
    }

    private static let spoken = Transcript.fixture(text: "der termin steht", profile: .german, secondsPerWord: 0.2)

    // MARK: - The sentence is not taken back

    func testADeviceChangeMidSentenceStillDeliversWhatWasSaid() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }

        harness.capture.triggerInterruption(.inputDeviceChanged)

        try await waitUntil("the text is delivered") { harness.coordinator.lastInsertion != nil }
        XCTAssertEqual(harness.insertion.insertedText, "Der termin steht.")
    }

    func testTheAppDoesNotEndUpInAFailureStateOverIt() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }

        harness.capture.triggerInterruption(.inputDeviceChanged)

        try await waitUntil("the app settles") { harness.coordinator.state == .ready }
        if case .failed = harness.coordinator.state {
            XCTFail("A device change is not a failure of the app; the words still arrived")
        }
    }

    func testTheUserIsToldWhyItStoppedAndThatNothingWasLost() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }

        harness.capture.triggerInterruption(.inputDeviceChanged)
        try await waitUntil("the notice appears") { harness.coordinator.captureInterruption != nil }

        let message = try XCTUnwrap(harness.coordinator.captureInterruptionMessage)
        XCTAssertTrue(message.contains("microphone changed"))
        XCTAssertTrue(message.contains("already said was kept"))
    }

    /// A recording the user ended by releasing the key is not the device's to
    /// take credit for, even when a device change lands during the stop.
    func testAnInterruptionDuringANormalFinishBlamesNobody() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }

        harness.hotkey.emit(.released)
        harness.capture.triggerInterruption(.inputDeviceChanged)

        try await waitUntil("the app settles") { harness.coordinator.state == .ready }
        XCTAssertNil(harness.coordinator.captureInterruption)
    }

    func testTheCaptureIsStoppedExactlyOnce() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }

        harness.capture.triggerInterruption(.inputDeviceChanged)
        harness.capture.triggerInterruption(.inputDeviceChanged)

        try await waitUntil("the app settles") { harness.coordinator.state == .ready }
        XCTAssertEqual(harness.capture.stopReasons, [.interrupted])
    }

    // MARK: - Where nothing could be saved

    /// The engine never opened, so there is no audio to keep and the failure is
    /// the whole story.
    func testAnInterruptionBeforeTheEngineOpensIsStillAFailure() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.capture.delayStart(nanoseconds: 60_000_000)
        harness.hotkey.emit(.pressed)
        // The engine has to have been asked to open before it can report a
        // problem: the interruption handler is not installed until then.
        try await waitUntil("the engine is opening") { harness.capture.startCount == 1 }
        XCTAssertEqual(harness.coordinator.state, .starting)

        harness.capture.triggerInterruption(.noInputDevice)

        try await waitUntil("the failure lands") {
            if case .failed = harness.coordinator.state { return true }
            return false
        }
    }

    func testTheInterruptionExplainsAnEmptyResultRatherThanTheMicrophone() async throws {
        let harness = makeHarness(transcript: .empty(profile: .german, engineIdentifier: "fake"))
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }

        harness.capture.triggerInterruption(.inputDeviceChanged)
        try await waitUntil("the app settles") { harness.coordinator.state == .ready }

        XCTAssertNotNil(harness.coordinator.captureInterruption)
        XCTAssertNil(
            harness.coordinator.silentResult,
            "Sending the user to check a microphone that was working until it was unplugged is the wrong answer"
        )
    }

    func testTheNoticeDoesNotSurviveIntoTheNextDictation() async throws {
        let harness = makeHarness(transcript: Self.spoken)
        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }
        harness.capture.triggerInterruption(.inputDeviceChanged)
        try await waitUntil("the notice appears") { harness.coordinator.captureInterruption != nil }
        // The interrupted utterance is still transcribed — its words were
        // already said — and a press while that is in flight is not a next
        // dictation, it is a press the machine refuses. Waiting for the app to
        // be ready is the difference between testing the rule and testing how
        // busy the machine was.
        try await waitUntil("the app settles") { harness.coordinator.state == .ready }

        harness.hotkey.emit(.pressed)
        try await waitUntil("the next recording starts") { harness.coordinator.state == .recording }

        XCTAssertNil(harness.coordinator.captureInterruption)
    }

    // MARK: - What the user reads

    func testTheIdleStateSaysTheRecordingEndedEarly() {
        let presentation = StatusPresentation(
            state: .ready,
            binding: .optionSpace,
            captureInterruption: AudioCaptureError.inputDeviceChanged.interruptionMessage
        )

        XCTAssertEqual(presentation.title, "Recording ended early")
        XCTAssertEqual(presentation.tint, .warning)
    }

    func testAMarkedResultStillComesFirst() {
        let presentation = StatusPresentation(
            state: .ready,
            binding: .optionSpace,
            attentionIsPending: true,
            captureInterruption: AudioCaptureError.inputDeviceChanged.interruptionMessage
        )

        XCTAssertEqual(presentation.title, "Worth a look")
    }
}
