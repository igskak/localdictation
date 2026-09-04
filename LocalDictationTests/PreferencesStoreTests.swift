import XCTest
@testable import Witness

/// The third and last thing this app writes to disk.
///
/// `EntitlementStorePrivacyTests` asserts the exact field list of
/// `license.json` for a reason worth repeating here: a persisted payload is a
/// promise about what the app keeps, and a promise nobody checks is a promise
/// that drifts. Everything in this file is a choice the user made about the
/// app, and none of it is derived from anything that was said.
final class PreferencesStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preferences-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func store() -> FilePreferencesStore {
        FilePreferencesStore(url: directory.appendingPathComponent("preferences.json"))
    }

    func testTheFileHoldsSevenFieldsAndNothingElse() throws {
        let store = store()
        try store.save(.default)

        let data = try Data(contentsOf: store.url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            [
                "hotkeyKeyCode",
                "hotkeyModifiers",
                "hotkeyKeyLabel",
                "activation",
                "languageProfile",
                "insertsAutomatically",
                "hasChosenLanguages",
            ]
        )
    }

    /// A file written by a Phase 6 build. Everything in it has to survive, and
    /// the field it does not have has to read as "this user has not been asked
    /// which languages they speak" — because they have not.
    func testASettingsFileFromAnOlderBuildKeepsItsLanguages() throws {
        let store = store()
        try Data(
            """
            {
              "activation" : "toggle",
              "hotkeyKeyCode" : 38,
              "hotkeyKeyLabel" : "J",
              "hotkeyModifiers" : 1048576,
              "insertsAutomatically" : false,
              "languageProfile" : { "primary" : "ru", "secondary" : "uk" }
            }
            """.utf8
        ).write(to: store.url)

        let loaded = try store.load()

        XCTAssertEqual(loaded.languageProfile, .russianUkrainian)
        XCTAssertEqual(loaded.activation, .toggle)
        XCTAssertEqual(loaded.hotkeyKeyLabel, "J")
        XCTAssertFalse(loaded.insertsAutomatically)
        XCTAssertFalse(loaded.hasChosenLanguages)
    }

    func testASelectionOfThreeLanguagesSurvivesAReload() throws {
        let store = store()
        var preferences = Preferences.default
        preferences.languageProfile = LanguageProfile(.russian, .english, .ukrainian)
        preferences.hasChosenLanguages = true

        try store.save(preferences)

        XCTAssertEqual(try store.load(), preferences)
    }

    func testSettingsSurviveAReload() throws {
        let store = store()
        var preferences = Preferences.default
        preferences.hotkeyBinding = HotkeyBinding(keyCode: 38, modifiers: [.command, .shift], keyLabel: "J")
        preferences.activation = .toggle
        preferences.languageProfile = .ukrainianEnglish
        preferences.insertsAutomatically = false

        try store.save(preferences)

        XCTAssertEqual(try store.load(), preferences)
    }

    func testAMissingFileIsAFirstRunAndNotAFailure() throws {
        XCTAssertEqual(try store().load(), .default)
    }

    func testAnEmptyFileIsAlsoAFirstRun() throws {
        let store = store()
        try Data().write(to: store.url)

        XCTAssertEqual(try store.load(), .default)
    }

    func testAnUnreadableFileSurfacesAnActionableError() throws {
        let store = store()
        try Data("not json at all".utf8).write(to: store.url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .unreadable = error as? PreferencesStoreError else {
                return XCTFail("Expected an unreadable settings file to say so")
            }
        }
    }

    func testTheBindingRoundTripsThroughItsThreeStoredFields() {
        var preferences = Preferences.default
        let binding = HotkeyBinding(keyCode: 38, modifiers: [.command, .control], keyLabel: "J")

        preferences.hotkeyBinding = binding

        XCTAssertEqual(preferences.hotkeyKeyCode, 38)
        XCTAssertEqual(preferences.hotkeyKeyLabel, "J")
        XCTAssertEqual(preferences.hotkeyBinding, binding)
    }
}

/// What the app does with those settings once it has them.
@MainActor
final class CoordinatorPreferencesTests: XCTestCase {
    private func makeCoordinator(_ store: any PreferencesStore) -> (DictationCoordinator, FakeHotkeyService) {
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService(),
            preferencesStore: store
        )
        coordinator.activate()
        return (coordinator, hotkey)
    }

    func testStoredSettingsAreInForceBeforeTheHotkeyIsRegistered() {
        var stored = Preferences.default
        stored.hotkeyBinding = HotkeyBinding(keyCode: 38, modifiers: [.command], keyLabel: "J")
        stored.activation = .toggle
        stored.languageProfile = .russianEnglish
        stored.insertsAutomatically = false

        let (coordinator, hotkey) = makeCoordinator(InMemoryPreferencesStore(stored))

        XCTAssertEqual(coordinator.activation, .toggle)
        XCTAssertEqual(coordinator.languageProfile, .russianEnglish)
        XCTAssertFalse(coordinator.insertsAutomatically)
        XCTAssertEqual(
            hotkey.registeredBindings,
            [stored.hotkeyBinding],
            "Registering the default first and the stored one after would take ⌥Space from another app for a moment"
        )
    }

    func testChangingTheLanguageProfileIsRemembered() {
        let store = InMemoryPreferencesStore()
        let (coordinator, _) = makeCoordinator(store)

        coordinator.languageProfile = .ukrainianEnglish

        XCTAssertEqual(store.stored.languageProfile, .ukrainianEnglish)
    }

    /// The picker appears once. Saving the answer without the flag would put
    /// the question back in front of the user having already taken their reply.
    func testAnsweringTheFirstRunQuestionIsRememberedWithTheAnswer() {
        let store = InMemoryPreferencesStore()
        let (coordinator, _) = makeCoordinator(store)
        XCTAssertTrue(coordinator.needsLanguageSetup)

        coordinator.completeLanguageSetup(with: LanguageProfile(.russian, .english, .ukrainian))

        XCTAssertFalse(coordinator.needsLanguageSetup)
        XCTAssertEqual(store.stored.languageProfile, LanguageProfile(.russian, .english, .ukrainian))
        XCTAssertTrue(store.stored.hasChosenLanguages)
        XCTAssertEqual(store.saveCount, 1, "One answer is one write")
    }

    func testAUserWhoHasAnsweredIsNotAskedAgain() {
        var stored = Preferences.default
        stored.languageProfile = LanguageProfile(.german)
        stored.hasChosenLanguages = true

        let (coordinator, _) = makeCoordinator(InMemoryPreferencesStore(stored))

        XCTAssertFalse(coordinator.needsLanguageSetup)
    }

    func testReadingTheSettingsDoesNotWriteThemBack() {
        let store = InMemoryPreferencesStore()
        _ = makeCoordinator(store)

        XCTAssertEqual(store.saveCount, 0, "Applying stored settings must not look like the user changing them")
    }

    /// A binding with no modifier can only come from someone editing the file
    /// by hand. Registering it would take a bare key away from every
    /// application on the Mac.
    func testAHandEditedBindingWithNoModifierIsIgnored() {
        var stored = Preferences.default
        stored.hotkeyBinding = HotkeyBinding(keyCode: 49, modifiers: [], keyLabel: "Space")

        let (coordinator, _) = makeCoordinator(InMemoryPreferencesStore(stored))

        XCTAssertEqual(coordinator.binding, .optionSpace)
    }

    func testWithoutAStoreNothingIsPersistedAndNothingBreaks() {
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: FakeAudioCaptureService()
        )
        coordinator.activate()

        coordinator.setActivation(.toggle)
        coordinator.languageProfile = .german

        XCTAssertEqual(coordinator.activation, .toggle)
        XCTAssertNil(coordinator.preferencesErrorDescription)
        XCTAssertNil(coordinator.preferencesLocationDescription)
    }
}
