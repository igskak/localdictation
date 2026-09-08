import AppKit
import SwiftUI
import XCTest
@testable import Witness

/// Drives the settings window through real AppKit layout.
///
/// `ReviewPanelControllerTests` exists because a SwiftUI view crashed the app
/// the first time it appeared while every unit test passed. Settings grew three
/// new sections — a shortcut recorder, a mode picker, and a login-item switch —
/// and none of them is reachable by a test that never renders anything.
///
/// An AppKit or SwiftUI exception here takes the test process down rather than
/// failing politely. That is the point: a crash in the suite is a crash caught
/// before the user sees it.
@MainActor
final class SettingsViewLayoutTests: XCTestCase {
    private func makeCoordinator(
        preferences: Preferences = .default,
        secureInput: SecureInputState = .off,
        hotkeyFailure: (any Error)? = nil,
        entitlement: EntitlementService? = nil
    ) -> DictationCoordinator {
        let hotkey = FakeHotkeyService()
        if let hotkeyFailure { hotkey.failRegistration(with: hotkeyFailure) }
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService(),
            transcriptionService: FakeTranscriptionService(),
            glossaryStore: InMemoryGlossaryStore(.empty),
            accessibilityService: FakeAccessibilityPermissionService(authorization: .trusted),
            insertionService: FakeTextInsertionService(),
            entitlementService: entitlement,
            preferencesStore: InMemoryPreferencesStore(preferences),
            secureInputSource: FakeSecureInputSource(secureInput)
        )
        coordinator.activate()
        return coordinator
    }

    /// Renders the whole settings window and measures it, which is what forces
    /// SwiftUI to lay every row out for real.
    @discardableResult
    private func render(_ coordinator: DictationCoordinator) -> NSSize {
        let hosting = NSHostingView(rootView: SettingsView().environmentObject(coordinator))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.removeFromSuperview()
        return size
    }

    private func settle(_ turns: Int = 4) async throws {
        for _ in 0..<turns {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTheSettingsWindowLaysOutWithDefaults() async throws {
        let size = render(makeCoordinator())

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        try await settle()
    }

    /// Every row that only appears in a state something has gone wrong in. Each
    /// is a branch the ordinary render never reaches.
    func testTheWindowLaysOutWithEveryWarningRowShowing() async throws {
        let coordinator = makeCoordinator(
            secureInput: SecureInputState(isEnabled: true, holderName: "1Password"),
            hotkeyFailure: HotkeyRegistrationError.alreadyInUse
        )

        render(coordinator)
        try await settle()
    }

    func testTheWindowLaysOutWhileAShortcutIsBeingCaptured() async throws {
        let coordinator = makeCoordinator()
        coordinator.beginHotkeyCapture()

        render(coordinator)
        try await settle()

        coordinator.cancelHotkeyCapture()
    }

    func testTheWindowLaysOutInToggleMode() async throws {
        var preferences = Preferences.default
        preferences.activation = .toggle
        preferences.hotkeyBinding = HotkeyBinding(keyCode: 38, modifiers: [.command, .shift], keyLabel: "J")

        render(makeCoordinator(preferences: preferences))
        try await settle()
    }

    /// The menu is the other view the new state reaches.
    func testTheMenuLaysOutWithTheSecureInputWarning() async throws {
        let coordinator = makeCoordinator(
            secureInput: SecureInputState(isEnabled: true, holderName: "1Password")
        )
        try await renderMenu(coordinator)
    }

    /// The countdown row, laid out for real. It is the one licensing view that
    /// appears while everything else in the menu is also on screen, so it is
    /// the one most likely to be laid out next to something it was never seen
    /// beside.
    func testTheMenuLaysOutWithTheEntitlementCountdown() async throws {
        // The notice only exists on the last of the three ungated days.
        let coordinator = makeCoordinator(entitlement: makeEntitlementService(daysElapsed: 2.5))

        XCTAssertNotNil(EntitlementNotice(state: coordinator.entitlement))
        try await renderMenu(coordinator)
    }

    /// And the wall itself, which replaces it.
    func testTheMenuLaysOutWithTheLicensingWall() async throws {
        let coordinator = makeCoordinator(entitlement: makeEntitlementService(daysElapsed: 4))

        XCTAssertEqual(coordinator.entitlement, .locked(.activationRequired))
        try await renderMenu(coordinator)
    }

    private func renderMenu(_ coordinator: DictationCoordinator) async throws {
        let hosting = NSHostingView(rootView: MenuBarView().environmentObject(coordinator))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        hosting.removeFromSuperview()
        try await settle()
    }

    /// A licensing service that is already some way into the ungated window,
    /// without a file. The window is three days, so getting into it means
    /// moving a clock rather than pressing something repeatedly.
    ///
    /// Anchored to the real clock rather than a fixed epoch, because the views
    /// being laid out build their own `EntitlementNotice` against `Date()`. A
    /// record whose deadline sits in 2023 produces no notice and the test would
    /// pass by rendering nothing.
    private func makeEntitlementService(daysElapsed: Double) -> EntitlementService {
        let firstDictation = Date().addingTimeInterval(-daysElapsed * 86_400)
        let clock = TestClock(firstDictation)
        let service = EntitlementService(
            store: InMemoryEntitlementStore(),
            authority: LicenseAuthority(publicKeyBase64: ""),
            deviceIdentity: FixedDeviceIdentity("0123456789abcdef0123456789abcdef"),
            telemetry: RecordingTelemetryService(),
            clock: { clock.value }
        )
        service.recordSuccessfulDictation()
        clock.set(Date())
        service.refresh()
        return service
    }
}
