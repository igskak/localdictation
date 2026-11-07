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

    func testReinstallationShowsSetupButRestartAfterSkipDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("onboarding.json")
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        func controller(_ identity: String) -> LanguageSetupWindowController {
            LanguageSetupWindowController(coordinator: coordinator, loginItem: FakeLoginItemService(),
                installationAware: true, receiptURL: receipt, installationIdentity: identity)
        }
        let first = controller("first-copy")
        first.presentIfNeeded()
        XCTAssertTrue(first.isPresenting)
        first.finish()
        let restart = controller("first-copy")
        restart.presentIfNeeded()
        XCTAssertFalse(restart.isPresenting)
        let reinstall = controller("second-copy")
        reinstall.presentIfNeeded()
        XCTAssertTrue(reinstall.isPresenting)
        reinstall.finish()
    }

    func testGuidedSetupPagesFitAndRender() throws {
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        let model = LanguageSetupModel(selection: .default)
        for page in 0...5 {
            model.page = page
            let view = GuidedSetupView(model: model, coordinator: coordinator, notifyWhenReady: {}, finish: {})
                .environmentObject(coordinator)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, 621)
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: "/tmp/witness-setup-\(page).png"))
                }
            }
        }
    }

    /// Exports the actual SwiftUI screens with injected permission/model fixtures.
    /// Used for reviewing onboarding without a microphone or live model download.
    func testExportOnboardingPreview() async throws {
        let directory = URL(fileURLWithPath: "/tmp/witness-onboarding-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = FakeTranscriptionService()
        engine.setResult(.fixture(words: [("Hello", 0.99), ("from", 0.99), ("Witness.", 0.99)]))
        let hotkey = FakeHotkeyService()
        let microphone = FakeMicrophonePermissionService(authorization: .notDetermined)
        let coordinator = DictationCoordinator(
            permissionService: microphone, hotkeyService: hotkey,
            captureService: FakeAudioCaptureService(), transcriptionService: engine,
            accessibilityService: FakeAccessibilityPermissionService(authorization: .notTrusted),
            insertionService: FakeTextInsertionService(),
            preferencesStore: InMemoryPreferencesStore()
        )
        coordinator.activate()
        await coordinator.refreshTranscriptionModelState()
        let model = LanguageSetupModel(selection: .default)
        func snapshot(_ name: String, afterLayout: (() async throws -> Void)? = nil) async throws {
            let hosting = NSHostingView(rootView: FirstRunView(
                model: model, coordinator: coordinator, confirm: {}, finish: {}, notifyWhenReady: {}
            ).environmentObject(coordinator).environment(\.locale, Locale(identifier: "en")))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
            hosting.layoutSubtreeIfNeeded()
            try await settle()
            try await afterLayout?()
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            window.close()
        }
        model.step = .welcome
        try await snapshot("01-welcome")
        model.step = .languages
        try await snapshot("02-languages")
        model.step = .ready; model.page = 0
        try await snapshot("03-microphone")
        await coordinator.requestMicrophoneAccess()
        model.page = 1
        try await snapshot("04-accessibility")
        model.page = 2
        try await snapshot("05-key")
        engine.setModelState(.preparing(ModelPreparation(phase: .downloading, download: ModelDownloadProgress(
            completedBytes: 688_000_000, totalBytes: 1_600_000_000, remainingSeconds: 360
        ))))
        await coordinator.refreshTranscriptionModelState()
        model.page = 3
        try await snapshot("06-model-download")
        engine.setModelState(.ready)
        await coordinator.refreshTranscriptionModelState()
        model.page = 4
        try await snapshot("07-try-dictation")
        model.page = 4
        try await snapshot("08-dictation-result") {
            coordinator.beginOnboardingTest()
            hotkey.emit(.pressed); hotkey.emit(.released)
            try await waitUntil("preview dictation result") { !coordinator.onboardingTestText.isEmpty }
        }
        model.page = 5
        try await snapshot("09-ready")
        coordinator.deactivate()
    }

    // MARK: - The window

    func testTheQuestionLaysOutWithAHundredLanguagesInIt() {
        let model = LanguageSetupModel(selection: .default)
        let size = render(LanguageSetupView(model: model) {})

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testBothFirstRunScreensLayOutInTheExpansionLocales() {
        for identifier in ["es", "it", "fr"] {
            let model = LanguageSetupModel(selection: .default)
            let question = LanguageSetupView(model: model) {}
                .environment(\.locale, Locale(identifier: identifier))
            let questionSize = render(question)

            let (coordinator, _, _) = makeUnpermittedCoordinator()
            let permissions = FirstRunReadyView(coordinator: coordinator) {}
                .environment(\.locale, Locale(identifier: identifier))
            let permissionsSize = render(permissions)

            XCTAssertEqual(questionSize.width, 520, accuracy: 1, identifier)
            XCTAssertEqual(permissionsSize.width, 520, accuracy: 1, identifier)
            XCTAssertGreaterThan(questionSize.height, 0, identifier)
            XCTAssertGreaterThan(permissionsSize.height, 0, identifier)
        }
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
