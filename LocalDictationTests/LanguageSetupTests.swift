import AppKit
import SwiftUI
import XCTest
@testable import Witness

/// The first-run question, driven through real AppKit layout.
///
/// `ReviewPanelControllerTests` exists because a SwiftUI view crashed the app
/// the first time it appeared while every unit test passed. This is the same
/// risk in the same shape: a window nobody sees until a first run, holding a
/// hundred-row list, shown before anything else in the app has happened.
@MainActor
final class LanguageSetupTests: XCTestCase {
    private func makeCoordinator(_ store: any PreferencesStore) -> DictationCoordinator {
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            transcriptionService: FakeTranscriptionService(),
            glossaryStore: InMemoryGlossaryStore(.empty),
            preferencesStore: store
        )
        coordinator.activate()
        return coordinator
    }

    @discardableResult
    private func render(_ view: some View, width: CGFloat = 520, height: CGFloat = 620) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
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

    // MARK: - The window

    func testTheQuestionLaysOutWithAHundredLanguagesInIt() {
        let model = LanguageSetupModel(selection: .default)
        let size = render(LanguageSetupView(model: model) {})

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testTheEditorLaysOutOnItsOwnAsSettingsShowsIt() {
        var profile = LanguageProfile(.russian, .english, .ukrainian)
        let size = render(
            LanguageSelectionEditor(selection: Binding(get: { profile }, set: { profile = $0 })),
            width: 520,
            height: 420
        )

        XCTAssertGreaterThan(size.height, 0)
    }

    func testTheWindowOpensOnlyWhileTheQuestionIsUnanswered() async throws {
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        let controller = LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService())

        controller.presentIfNeeded()
        try await settle()
        XCTAssertTrue(controller.isAsking)
        XCTAssertTrue(coordinator.needsLanguageSetup, "Showing the question is not answering it")

        // A second call must bring the same window forward rather than build
        // another one.
        let window = controller.window
        controller.presentIfNeeded()
        try await settle()
        XCTAssertIdentical(controller.window, window)

        controller.window?.close()
        try await settle()
    }

    /// From the first live launch: the window was closed without ever having
    /// been read, and closing used to count as an answer. It recorded German
    /// and English — which nobody had chosen — and never asked again.
    func testClosingTheWindowAnswersNothing() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService())
        controller.presentIfNeeded()
        try await settle()

        controller.window?.close()
        try await settle()

        XCTAssertTrue(coordinator.needsLanguageSetup, "The next launch has to ask again")
        XCTAssertFalse(store.stored.hasChosenLanguages)
        XCTAssertEqual(store.saveCount, 0, "A question nobody answered writes nothing")
    }

    func testContinueIsWhatRecordsTheAnswer() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService())
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        try await settle()

        XCTAssertFalse(coordinator.needsLanguageSetup)
        XCTAssertTrue(store.stored.hasChosenLanguages)
        XCTAssertEqual(store.stored.languageProfile, .default)
        XCTAssertFalse(controller.isAsking, "Answering closes the question")
        XCTAssertTrue(controller.isPresenting, "and hands the window to what to do next")

        controller.finish()
        try await settle()
        XCTAssertFalse(controller.isPresenting)
    }

    /// The half of the first run that used to be missing. A menu bar utility
    /// with no Dock icon and no window has to say what the hotkey is, or the
    /// person who just installed it has nothing to press.
    func testWhatToDoNextLaysOutAndNamesTheHotkey() async throws {
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        let size = render(FirstRunReadyView(coordinator: coordinator) {})

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(coordinator.binding.displayString, "\u{2325}Space")
    }

    /// Closing the second screen is not an unanswered question, so it must not
    /// bring the first one back at the next launch.
    func testClosingAfterTheAnswerDoesNotReopenTheQuestion() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService())
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        controller.window?.close()
        try await settle()

        XCTAssertFalse(coordinator.needsLanguageSetup)
        XCTAssertTrue(store.stored.hasChosenLanguages)
    }

    /// Answering and then closing is one answer, not an answer followed by a
    /// question left open.
    func testAnsweringThenClosingRecordsOnce() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService())
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        controller.confirmSelection()
        try await settle()

        XCTAssertEqual(store.saveCount, 1)
        XCTAssertFalse(coordinator.needsLanguageSetup)
    }

    // MARK: - Opening at login

    /// The reason the switch exists: the hotkey belongs to a running app, and a
    /// restart leaves a menu bar app with no Dock icon not running.
    func testTheFirstRunOpensTheAppAtLoginUnlessTheSwitchIsOff() async throws {
        let loginItem = FakeLoginItemService(.disabled)
        let controller = LanguageSetupWindowController(coordinator: makeCoordinator(InMemoryPreferencesStore()), loginItem: loginItem)
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        XCTAssertEqual(loginItem.calls, [], "nothing is registered while the choice is still on screen")

        controller.window?.close()
        try await settle()

        XCTAssertEqual(loginItem.calls, [true])
        XCTAssertTrue(loginItem.state.isEnabled)
    }

    func testSwitchingItOffOnTheSecondScreenIsHonoured() async throws {
        let loginItem = FakeLoginItemService(.disabled)
        let controller = LanguageSetupWindowController(coordinator: makeCoordinator(InMemoryPreferencesStore()), loginItem: loginItem)
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        controller.setOpensAtLoginForTesting(false)
        controller.window?.close()
        try await settle()

        XCTAssertEqual(loginItem.calls, [])
    }

    /// Closing the language question without answering it is "not now": no
    /// language is recorded and nothing is registered either.
    func testClosingTheQuestionUnansweredRegistersNothing() async throws {
        let loginItem = FakeLoginItemService(.disabled)
        let controller = LanguageSetupWindowController(coordinator: makeCoordinator(InMemoryPreferencesStore()), loginItem: loginItem)
        controller.presentIfNeeded()
        try await settle()

        controller.window?.close()
        try await settle()

        XCTAssertEqual(loginItem.calls, [])
    }

    /// An item the person switched off in System Settings is an answer, and so
    /// is one that is already on.
    func testItNeverOverrulesAnAnswerMacOSAlreadyHolds() async throws {
        for state in [LoginItemState.requiresApproval, .enabled, .unavailable("moved")] {
            let loginItem = FakeLoginItemService(state)
            let controller = LanguageSetupWindowController(coordinator: makeCoordinator(InMemoryPreferencesStore()), loginItem: loginItem)
            controller.presentIfNeeded()
            try await settle()

            controller.confirmSelection()
            controller.window?.close()
            try await settle()

            XCTAssertEqual(loginItem.calls, [], "\(state)")
        }
    }

    /// A Mac that has already answered the language question is an existing
    /// install, and the first-run default does not reach it.
    func testAnExistingInstallIsNotChanged() async throws {
        var stored = Preferences.default
        stored.hasChosenLanguages = true
        let loginItem = FakeLoginItemService(.disabled)
        let controller = LanguageSetupWindowController(coordinator: makeCoordinator(InMemoryPreferencesStore(stored)), loginItem: loginItem)

        controller.presentIfNeeded()
        try await settle()

        XCTAssertNil(controller.window)
        XCTAssertEqual(loginItem.calls, [])
    }

    func testTheSecondScreenLaysOutWithTheLoginSwitchOnIt() {
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        let size = render(FirstRunReadyView(coordinator: coordinator, opensAtLogin: .constant(true)) {})

        XCTAssertGreaterThan(size.height, 0)
    }

    func testTheLoginSwitchCopyHasGermanAndTheSwitchStartsOn() throws {
        XCTAssertTrue(LanguageSetupModel(selection: .default).opensAtLogin)

        let path = try XCTUnwrap(L10n.bundle.path(forResource: "de", ofType: "lproj"))
        let german = try XCTUnwrap(Bundle(path: path))
        for key in ["Open Witness when I log in", "The hotkey only works while Witness is running, and it has no Dock icon. Without this, a restart leaves the hotkey silent until you open the app again."] {
            XCTAssertNotEqual(german.localizedString(forKey: key, value: nil, table: nil), key)
        }
    }

    func testAnAnsweredQuestionIsNotAskedAgain() async throws {
        var stored = Preferences.default
        stored.hasChosenLanguages = true
        let coordinator = makeCoordinator(InMemoryPreferencesStore(stored))
        let controller = LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService())

        controller.presentIfNeeded()
        try await settle()

        XCTAssertFalse(controller.isAsking)
        XCTAssertNil(controller.window)
    }

    // MARK: - The two permissions

    /// A coordinator whose permissions are all still unanswered, which is the
    /// state a fresh install is actually in.
    private func makeUnpermittedCoordinator() -> (
        DictationCoordinator,
        FakeMicrophonePermissionService,
        FakeAccessibilityPermissionService
    ) {
        let microphone = FakeMicrophonePermissionService(authorization: .notDetermined)
        let accessibility = FakeAccessibilityPermissionService(authorization: .notTrusted)
        let coordinator = DictationCoordinator(
            permissionService: microphone,
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            transcriptionService: FakeTranscriptionService(),
            glossaryStore: InMemoryGlossaryStore(.empty),
            accessibilityService: accessibility,
            insertionService: FakeTextInsertionService(),
            preferencesStore: InMemoryPreferencesStore()
        )
        coordinator.activate()
        return (coordinator, microphone, accessibility)
    }

    /// The friend's first question, in a test: every other app on the Mac asks
    /// at launch, and leaving both asks in a menu bar window meant a product
    /// that looked broken until they were found.
    func testTheFirstRunAsksForBothPermissions() async throws {
        let (coordinator, microphone, accessibility) = makeUnpermittedCoordinator()

        await coordinator.requestFirstRunPermissions()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertEqual(accessibility.requestCount, 1)
        XCTAssertEqual(coordinator.microphoneAuthorization, .authorized)
    }

    /// Once per launch. The prompts belong to macOS, which shows each of them
    /// once anyway, and a view rebuilt for any reason must not ask again.
    func testThePermissionsAreAskedForOnce() async throws {
        let (coordinator, microphone, accessibility) = makeUnpermittedCoordinator()

        await coordinator.requestFirstRunPermissions()
        await coordinator.requestFirstRunPermissions()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertEqual(accessibility.requestCount, 1)
    }

    /// Nothing is asked for twice, and nothing is asked for that has already
    /// been granted: a returning user who answered both is not prompted at all.
    func testGrantedPermissionsAreNotAskedForAgain() async throws {
        let microphone = FakeMicrophonePermissionService(authorization: .authorized)
        let accessibility = FakeAccessibilityPermissionService(authorization: .trusted)
        let coordinator = DictationCoordinator(
            permissionService: microphone,
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            transcriptionService: FakeTranscriptionService(),
            accessibilityService: accessibility,
            insertionService: FakeTextInsertionService(),
            preferencesStore: InMemoryPreferencesStore()
        )
        coordinator.activate()

        await coordinator.requestFirstRunPermissions()

        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(accessibility.requestCount, 0)
    }

    /// The screen that does the asking has to survive a real layout pass with
    /// every row in the state a first run finds them in.
    func testTheReadyScreenLaysOutWhileNothingIsGrantedYet() {
        let (coordinator, _, _) = makeUnpermittedCoordinator()
        let size = render(FirstRunReadyView(coordinator: coordinator) {})

        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: - The selection itself

    func testTheQuestionOpensWithWhatTheAppAlreadyHad() {
        var stored = Preferences.default
        stored.languageProfile = .russianUkrainian
        let coordinator = makeCoordinator(InMemoryPreferencesStore(stored))

        let model = LanguageSetupModel(selection: coordinator.languageProfile)

        XCTAssertEqual(model.selection, .russianUkrainian)
    }
}
