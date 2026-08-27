import XCTest
@testable import LocalDictation

/// Changing the shortcut, and the two ways that can go wrong.
///
/// ⌥Space is a default, not a law. Carbon offers no way to ask whether a
/// combination is free — the only way to find out is to register it — so every
/// path here has to survive a refusal and leave the user with a working app.
@MainActor
final class HotkeyBindingTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let preferences: InMemoryPreferencesStore
    }

    private func makeHarness() -> Harness {
        let hotkey = FakeHotkeyService()
        let preferences = InMemoryPreferencesStore()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService(),
            preferencesStore: preferences
        )
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, preferences: preferences)
    }

    private static let commandJ = HotkeyBinding(keyCode: 38, modifiers: [.command], keyLabel: "J")

    // MARK: - Changing it

    func testAFreeCombinationIsTakenAndRemembered() {
        let harness = makeHarness()

        let error = harness.coordinator.changeHotkey(to: Self.commandJ)

        XCTAssertNil(error)
        XCTAssertEqual(harness.coordinator.binding, Self.commandJ)
        XCTAssertEqual(harness.hotkey.registeredBinding, Self.commandJ)
        XCTAssertEqual(harness.preferences.stored.hotkeyBinding, Self.commandJ)
    }

    func testACombinationSomethingElseOwnsLeavesTheWorkingOneInPlace() {
        let harness = makeHarness()
        harness.hotkey.failNextRegistration(with: HotkeyRegistrationError.alreadyInUse)

        let error = harness.coordinator.changeHotkey(to: Self.commandJ)

        XCTAssertEqual(error, .alreadyInUse)
        XCTAssertEqual(harness.coordinator.binding, .optionSpace)
        XCTAssertEqual(
            harness.hotkey.registeredBinding,
            .optionSpace,
            "A refused combination must not cost the user the shortcut they had"
        )
        XCTAssertEqual(harness.preferences.stored.hotkeyBinding, .optionSpace)
    }

    /// Registering a bare key takes it away from every application on the Mac,
    /// including this app's own text fields, so it never reaches the system.
    func testACombinationWithNoModifierIsRefusedBeforeItReachesTheSystem() {
        let harness = makeHarness()
        let registrationsBefore = harness.hotkey.registerCount

        let error = harness.coordinator.changeHotkey(
            to: HotkeyBinding(keyCode: 49, modifiers: [], keyLabel: "Space")
        )

        XCTAssertEqual(error, .noModifier)
        XCTAssertEqual(harness.hotkey.registerCount, registrationsBefore)
        XCTAssertEqual(harness.coordinator.binding, .optionSpace)
    }

    func testResettingReturnsToTheDefault() {
        let harness = makeHarness()
        harness.coordinator.changeHotkey(to: Self.commandJ)

        harness.coordinator.resetHotkey()

        XCTAssertEqual(harness.coordinator.binding, .optionSpace)
        XCTAssertEqual(harness.hotkey.registeredBinding, .optionSpace)
    }

    /// A registration failure is a state the app shows. Fixing it by choosing a
    /// working combination has to clear that state, or the app stays
    /// broken-looking after it has been fixed.
    func testChoosingAWorkingCombinationClearsTheFailureState() {
        let harness = makeHarness()
        harness.coordinator.deactivate()
        harness.hotkey.failNextRegistration(with: HotkeyRegistrationError.alreadyInUse)
        harness.coordinator.activate()
        guard case .failed(.hotkeyRegistration) = harness.coordinator.state else {
            return XCTFail("Expected the app to report the shortcut it could not register")
        }

        harness.coordinator.changeHotkey(to: Self.commandJ)

        XCTAssertEqual(harness.coordinator.state, .ready)
    }

    // MARK: - Capturing one

    func testCapturingReleasesTheCurrentShortcutSoTheUserCanPressIt() {
        let harness = makeHarness()

        harness.coordinator.beginHotkeyCapture()

        XCTAssertTrue(harness.coordinator.isCapturingHotkey)
        XCTAssertNil(
            harness.coordinator.registeredHotkey,
            "A registered Carbon hotkey eats its combination before any window sees it"
        )
        XCTAssertEqual(harness.hotkey.registeredBinding, nil)
    }

    func testCancellingACaptureGivesTheShortcutBack() {
        let harness = makeHarness()
        harness.coordinator.beginHotkeyCapture()

        harness.coordinator.cancelHotkeyCapture()

        XCTAssertFalse(harness.coordinator.isCapturingHotkey)
        XCTAssertEqual(harness.hotkey.registeredBinding, .optionSpace)
    }

    /// The settings window closing mid-capture goes through the same path, and
    /// it is the one that matters most: it would otherwise leave the app with
    /// no shortcut at all and nothing on screen saying so.
    func testPressingTheCombinationTheUserAlreadyHasIsNotALostShortcut() {
        let harness = makeHarness()
        harness.coordinator.beginHotkeyCapture()

        let error = harness.coordinator.finishHotkeyCapture(with: .optionSpace)

        XCTAssertNil(error)
        XCTAssertEqual(harness.hotkey.registeredBinding, .optionSpace)
        XCTAssertFalse(harness.coordinator.isCapturingHotkey)
    }

    func testAModifierlessCaptureRefusesAndStillGivesTheShortcutBack() {
        let harness = makeHarness()
        harness.coordinator.beginHotkeyCapture()

        let error = harness.coordinator.finishHotkeyCapture(
            with: HotkeyBinding(keyCode: 38, modifiers: [], keyLabel: "J")
        )

        XCTAssertEqual(error, .noModifier)
        XCTAssertEqual(harness.hotkey.registeredBinding, .optionSpace)
    }

    /// Nothing may quietly re-register while the user is choosing — the app
    /// re-reads authorization on every activation, and this app is activated by
    /// the very window the capture happens in.
    func testAnAuthorizationRefreshDoesNotInterruptACapture() {
        let harness = makeHarness()
        harness.coordinator.beginHotkeyCapture()

        harness.coordinator.refreshAuthorization()

        XCTAssertTrue(harness.coordinator.isCapturingHotkey)
        XCTAssertNil(harness.coordinator.registeredHotkey)
    }

    // MARK: - What it is called

    func testKeysWithNoCharacterAreNamed() {
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 49, characters: " "), "Space")
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 53, characters: nil), "Escape")
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 126, characters: nil), "↑")
    }

    /// The label comes from the event because a key code names a position, not
    /// a letter: key 12 is Q on QWERTY, A on AZERTY, and an apostrophe on Dvorak.
    func testALetterIsNamedByWhatTheKeyboardActuallyProduces() {
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 12, characters: "a"), "A")
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 12, characters: "й"), "Й")
    }

    func testAnUnprintableCharacterNeverBecomesTheLabel() {
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 200, characters: "\u{1}"), "Key 200")
        XCTAssertEqual(HotkeyKeyLabel.label(forKeyCode: 201, characters: ""), "Key 201")
    }

    func testTheDisplayStringPutsModifiersInTheOrderMacOSDoes() {
        let binding = HotkeyBinding(keyCode: 38, modifiers: [.command, .shift, .option], keyLabel: "J")
        XCTAssertEqual(binding.displayString, "⌥⇧⌘J")
    }
}
