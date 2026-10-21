import XCTest
@testable import Witness

@MainActor
final class NotetakerAvailabilityTests: XCTestCase {
    func testLiveDefaultIsDisabled() {
        XCTAssertEqual(NotetakerAvailability.liveDefault, .disabled)
    }

    func testDisabledCompositionCreatesNoNotetakerEffectsAndPreservesDictation() {
        let permissions = FakeMicrophonePermissionService(authorization: .authorized)
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let coordinator = DictationCoordinator(
            permissionService: permissions,
            hotkeyService: hotkey,
            captureService: capture
        )
        let builder = SideEffectingNotetakerBuilder()
        var dictationBuildCount = 0

        let composition = ApplicationComposition.make(
            notetakerAvailability: .disabled,
            makeDictationCoordinator: {
                dictationBuildCount += 1
                return coordinator
            },
            makeAvailableNotetaker: builder.build
        )

        XCTAssertEqual(dictationBuildCount, 1)
        XCTAssertTrue(composition.dictationCoordinator === coordinator)
        XCTAssertEqual(builder.buildCount, 0)
        XCTAssertEqual(builder.permissionCheckCount, 0)
        XCTAssertEqual(builder.detectorStartCount, 0)
        XCTAssertEqual(builder.persistenceOpenCount, 0)
        XCTAssertNil(composition.notetaker.menuBarItem)

        composition.notetaker.activate()
        composition.notetaker.deactivate()
        XCTAssertEqual(builder.permissionCheckCount, 0)
        XCTAssertEqual(builder.detectorStartCount, 0)
        XCTAssertEqual(builder.persistenceOpenCount, 0)

        composition.dictationCoordinator.activate()
        XCTAssertEqual(composition.dictationCoordinator.state, .ready)
        XCTAssertEqual(hotkey.registerCount, 1)
        XCTAssertEqual(capture.startCount, 0)
    }

    func testEnabledCompositionUsesTheInjectedBuilder() {
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService()
        )
        let builder = SideEffectingNotetakerBuilder()

        let composition = ApplicationComposition.make(
            notetakerAvailability: .enabled,
            makeDictationCoordinator: { coordinator },
            makeAvailableNotetaker: builder.build
        )

        XCTAssertEqual(builder.buildCount, 1)
        XCTAssertEqual(builder.permissionCheckCount, 1)
        XCTAssertEqual(builder.detectorStartCount, 1)
        XCTAssertEqual(builder.persistenceOpenCount, 1)
        XCTAssertNotNil(composition.notetaker.menuBarItem)
    }

    func testMenuBarStatusRepresentsMeetingLifecycleWithoutAnotherStatusItem() {
        let status = NotetakerStatus()
        XCTAssertNil(status.systemImage)
        XCTAssertFalse(status.isActive)

        status.update(.suggestion)
        XCTAssertEqual(status.systemImage, "note.text.badge.plus")
        XCTAssertEqual(status.accessibilityLabel, "Witness found a possible meeting")
        XCTAssertFalse(status.isActive)

        status.update(.recording)
        XCTAssertEqual(status.systemImage, "record.circle.fill")
        XCTAssertEqual(status.accessibilityLabel, "Witness is recording a meeting note")
        XCTAssertTrue(status.isActive)

        status.update(.finishing)
        XCTAssertEqual(status.systemImage, "hourglass")
        XCTAssertTrue(status.isActive)

        status.update(.attention)
        XCTAssertEqual(status.systemImage, "exclamationmark.triangle.fill")
        XCTAssertFalse(status.isActive)
    }
}

@MainActor
private final class SideEffectingNotetakerBuilder {
    private(set) var buildCount = 0
    private(set) var permissionCheckCount = 0
    private(set) var detectorStartCount = 0
    private(set) var persistenceOpenCount = 0

    func build() -> any NotetakerFacade {
        buildCount += 1
        permissionCheckCount += 1
        detectorStartCount += 1
        persistenceOpenCount += 1
        return TestNotetakerFacade()
    }
}

@MainActor
private final class TestNotetakerFacade: NotetakerFacade {
    let status = NotetakerStatus()

    var menuBarItem: NotetakerMenuItem? {
        NotetakerMenuItem(title: "Test meeting note", systemImage: "note.text", action: {})
    }

    func activate() {}
    func deactivate() {}
}
