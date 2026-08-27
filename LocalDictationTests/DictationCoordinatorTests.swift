import XCTest
@testable import LocalDictation

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        authorization: MicrophoneAuthorization = .authorized,
        requestResult: MicrophoneAuthorization = .authorized,
        hotkeyError: (any Error)? = nil
    ) -> (DictationCoordinator, FakeMicrophonePermissionService, FakeHotkeyService, FakeAudioCaptureService) {
        let permissions = FakeMicrophonePermissionService(authorization: authorization, requestResult: requestResult)
        let hotkey = FakeHotkeyService(registrationError: hotkeyError)
        let capture = FakeAudioCaptureService()
        let coordinator = DictationCoordinator(
            permissionService: permissions,
            hotkeyService: hotkey,
            captureService: capture,
            pollInterval: 0.02
        )
        return (coordinator, permissions, hotkey, capture)
    }

    func testActivationWithAuthorizedMicrophoneBecomesReady() {
        let (coordinator, _, hotkey, _) = makeCoordinator()
        coordinator.activate()

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(hotkey.registerCount, 1)
        XCTAssertEqual(coordinator.registeredHotkey, .optionSpace)
    }

    func testPressAndReleaseProducesExactlyOneUtterance() async throws {
        let (coordinator, _, hotkey, capture) = makeCoordinator()
        coordinator.activate()

        hotkey.emit(.pressed)
        try await waitUntil("recording starts") { coordinator.state == .recording }

        hotkey.emit(.released)
        try await waitUntil("recording completes") { coordinator.state == .ready }

        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.stopReasons, [.hotkeyRelease])
        XCTAssertNotNil(coordinator.diagnostics.lastUtterance)
        XCTAssertEqual(coordinator.diagnostics.lastUtterance?.endReason, .hotkeyRelease)
        XCTAssertEqual(coordinator.diagnostics.format?.outputSampleRate, AudioTargetFormat.sampleRate)
    }

    func testReleaseBeforeEngineStartsStillCompletesOneUtterance() async throws {
        let (coordinator, _, hotkey, capture) = makeCoordinator()
        capture.delayStart(nanoseconds: 40_000_000)
        coordinator.activate()

        hotkey.emit(.pressed)
        hotkey.emit(.released)

        try await waitUntil("delayed start finishes cleanly") { coordinator.state == .ready }
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testRepeatedShortRecordingsStayBalanced() async throws {
        let (coordinator, _, hotkey, capture) = makeCoordinator()
        coordinator.activate()

        for _ in 0..<25 {
            hotkey.emit(.pressed)
            try await waitUntil("recording starts") { coordinator.state == .recording }
            hotkey.emit(.released)
            try await waitUntil("recording completes") { coordinator.state == .ready }
        }

        XCTAssertEqual(capture.startCount, 25)
        XCTAssertEqual(capture.stopCount, 25)
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testDeniedPermissionBlocksRecordingWithoutCrashing() async throws {
        let (coordinator, permissions, hotkey, capture) = makeCoordinator(authorization: .denied)
        coordinator.activate()

        XCTAssertEqual(coordinator.state, .permissionDenied(restricted: false))

        hotkey.emit(.pressed)
        hotkey.emit(.released)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(coordinator.state, .permissionDenied(restricted: false))

        let presentation = StatusPresentation(state: coordinator.state, binding: coordinator.binding)
        XCTAssertTrue(presentation.showsSystemSettingsShortcut)

        coordinator.openSystemSettings()
        XCTAssertEqual(permissions.openSettingsCount, 1)
    }

    func testRestrictedPermissionIsReportedSeparately() {
        let (coordinator, _, _, _) = makeCoordinator(authorization: .restricted)
        coordinator.activate()
        XCTAssertEqual(coordinator.state, .permissionDenied(restricted: true))
    }

    func testPermissionIsRequestedOnlyOnExplicitAction() async {
        let (coordinator, permissions, _, _) = makeCoordinator(authorization: .notDetermined)
        coordinator.activate()

        XCTAssertEqual(coordinator.state, .needsPermission)
        XCTAssertEqual(permissions.requestCount, 0, "Activation must never trigger a permission dialog")

        await coordinator.requestMicrophoneAccess()
        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testDeniedRequestKeepsActionableState() async {
        let (coordinator, _, _, _) = makeCoordinator(authorization: .notDetermined, requestResult: .denied)
        coordinator.activate()
        await coordinator.requestMicrophoneAccess()

        XCTAssertEqual(coordinator.state, .permissionDenied(restricted: false))
    }

    func testCaptureStartFailureIsRecoverable() async throws {
        let (coordinator, _, hotkey, capture) = makeCoordinator()
        coordinator.activate()
        capture.failNextStart(with: .noInputDevice)

        hotkey.emit(.pressed)
        try await waitUntil("failure surfaces") {
            if case .failed = coordinator.state { return true }
            return false
        }
        XCTAssertEqual(
            coordinator.diagnostics.lastErrorDescription,
            RecordingFailure.captureStart(AudioCaptureError.noInputDevice.message).message
        )

        coordinator.recoverFromFailure()
        XCTAssertEqual(coordinator.state, .ready)

        hotkey.emit(.pressed)
        try await waitUntil("recording starts after recovery") { coordinator.state == .recording }
        hotkey.emit(.released)
        try await waitUntil("recording completes") { coordinator.state == .ready }
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testHotkeyRegistrationCollisionIsSurfaced() {
        let (coordinator, _, hotkey, _) = makeCoordinator(hotkeyError: HotkeyRegistrationError.alreadyInUse)
        coordinator.activate()

        XCTAssertEqual(coordinator.state, .failed(.hotkeyRegistration(HotkeyRegistrationError.alreadyInUse.message)))
        XCTAssertNil(coordinator.registeredHotkey)
        XCTAssertEqual(hotkey.registerCount, 1)

        let presentation = StatusPresentation(state: coordinator.state, binding: coordinator.binding)
        XCTAssertTrue(presentation.showsRecoveryAction)
    }

    /// An interruption tears the capture down and leaves the app usable. It no
    /// longer goes through `.failed` to get there: a device that changes while
    /// the user is speaking ends the recording, and the audio already in the
    /// buffer is finished rather than thrown away. `CaptureInterruptionTests`
    /// covers what then happens to it; this asserts the capture side.
    func testDeviceInterruptionStopsCaptureAndLeavesTheAppUsable() async throws {
        let (coordinator, _, hotkey, capture) = makeCoordinator()
        coordinator.activate()

        hotkey.emit(.pressed)
        try await waitUntil("recording starts") { coordinator.state == .recording }

        capture.triggerInterruption(.inputDeviceChanged)
        try await waitUntil("capture is torn down") { capture.stopCount == 1 }
        try await waitUntil("the app settles") { coordinator.state == .ready }

        XCTAssertEqual(capture.stopReasons, [.interrupted])
        XCTAssertEqual(coordinator.captureInterruption, .inputDeviceChanged)
        XCTAssertEqual(
            coordinator.diagnostics.lastErrorDescription,
            AudioCaptureError.inputDeviceChanged.message
        )
    }

    func testMaximumDurationEndsUtterance() async throws {
        let (coordinator, _, hotkey, capture) = makeCoordinator()
        coordinator.activate()

        hotkey.emit(.pressed)
        try await waitUntil("recording starts") { coordinator.state == .recording }

        capture.setSnapshot(
            CaptureSnapshot(
                frameCount: 1_920_000,
                capacityFrames: 1_920_000,
                peakLevel: 0.5,
                droppedFrameCount: 0,
                voiceActivity: VoiceActivityObservation(
                    state: .endedByMaximumDuration,
                    speechStart: 0.1,
                    trailingSilence: 0,
                    elapsed: 120,
                    lastWindowRMS: 0.01
                ),
                sampleRate: AudioTargetFormat.sampleRate
            )
        )
        coordinator.pollDiagnostics()

        try await waitUntil("maximum duration finishes capture") { coordinator.state == .ready }
        XCTAssertEqual(capture.stopReasons, [.maximumDuration])
        XCTAssertEqual(coordinator.diagnostics.lastUtterance?.endReason, .maximumDuration)
    }

    func testDeactivateReleasesHotkey() {
        let (coordinator, _, hotkey, _) = makeCoordinator()
        coordinator.activate()
        coordinator.deactivate()

        XCTAssertNil(coordinator.registeredHotkey)
        XCTAssertGreaterThanOrEqual(hotkey.unregisterCount, 1)
    }
}
