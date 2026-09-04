import XCTest
@testable import Witness

/// The second recording mode, which `docs/PRODUCT_SCOPE.md` has listed in the
/// MVP since the first draft and which was never built.
///
/// The two modes are not preferences about the same thing. Push-to-talk is a
/// key held for the length of a sentence; toggle is two presses around a
/// paragraph, and nobody holds a key for four minutes.
@MainActor
final class RecordingActivationTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let capture: FakeAudioCaptureService
        let preferences: InMemoryPreferencesStore
    }

    private func makeHarness(activation: RecordingActivation = .pushToTalk) -> Harness {
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let preferences = InMemoryPreferencesStore()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            preferencesStore: preferences,
            activation: activation
        )
        coordinator.activate()
        coordinator.setActivation(activation)
        return Harness(coordinator: coordinator, hotkey: hotkey, capture: capture, preferences: preferences)
    }

    // MARK: - Toggle

    func testInToggleModeLettingGoOfTheKeyDoesNotEndTheRecording() async throws {
        let harness = makeHarness(activation: .toggle)

        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }
        harness.hotkey.emit(.released)

        XCTAssertEqual(
            harness.coordinator.state,
            .recording,
            "Letting go of the key is the whole difference between the two modes"
        )
    }

    func testInToggleModeTheSecondPressFinishes() async throws {
        let harness = makeHarness(activation: .toggle)

        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }
        harness.hotkey.emit(.released)
        harness.hotkey.emit(.pressed)

        try await waitUntil("the utterance finishes") { harness.coordinator.state == .ready }
        XCTAssertEqual(harness.capture.stopReasons.count, 1)
    }

    /// A press arriving before the engine has finished starting still stops the
    /// recording, rather than being swallowed and leaving the microphone open.
    func testAToggleStopIsAcceptedWhileTheEngineIsStillStarting() async throws {
        let harness = makeHarness(activation: .toggle)
        harness.capture.delayStart(nanoseconds: 40_000_000)

        harness.hotkey.emit(.pressed)
        try await waitUntil("the app is starting") { harness.coordinator.state == .starting }
        harness.hotkey.emit(.pressed)

        try await waitUntil("the utterance finishes") { harness.coordinator.state == .ready }
    }

    func testInPushToTalkModeReleasingStillFinishes() async throws {
        let harness = makeHarness(activation: .pushToTalk)

        harness.hotkey.emit(.pressed)
        try await waitUntil("recording starts") { harness.coordinator.state == .recording }
        harness.hotkey.emit(.released)

        try await waitUntil("the utterance finishes") { harness.coordinator.state == .ready }
    }

    func testTheModeIsRemembered() {
        let harness = makeHarness(activation: .pushToTalk)

        harness.coordinator.setActivation(.toggle)

        XCTAssertEqual(harness.preferences.stored.activation, .toggle)
    }

    // MARK: - What the user is told to do

    func testTheInstructionMatchesTheMode() {
        let holding = StatusPresentation(state: .recording, binding: .optionSpace, activation: .pushToTalk)
        let toggling = StatusPresentation(state: .recording, binding: .optionSpace, activation: .toggle)

        XCTAssertTrue(holding.detail.contains("Release"))
        XCTAssertTrue(toggling.detail.contains("again"))
        XCTAssertFalse(
            toggling.detail.contains("Release"),
            "Telling a toggle-mode user to release the key is telling them to do the one thing that will not work"
        )
    }

    func testTheIdleInstructionMatchesTheMode() {
        XCTAssertTrue(
            StatusPresentation(state: .ready, binding: .optionSpace, activation: .pushToTalk).detail.contains("Hold")
        )
        XCTAssertTrue(
            StatusPresentation(state: .ready, binding: .optionSpace, activation: .toggle).detail.contains("Press")
        )
    }
}
