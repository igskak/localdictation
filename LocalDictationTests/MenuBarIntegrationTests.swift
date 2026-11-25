import AppKit
import SwiftUI
import XCTest
@testable import Witness

@MainActor
final class MenuBarIntegrationTests: XCTestCase {
    private func status(_ coordinator: DictationCoordinator) -> StatusPresentation {
        StatusPresentation(state: coordinator.state, binding: coordinator.binding,
            modelState: .ready, activation: coordinator.activation)
    }

    func testShortcutAndInstructionsTrackRebindingModeAndCaptureLifecycle() async throws {
        let hotkey = FakeHotkeyService(), capture = FakeAudioCaptureService()
        let coordinator = DictationCoordinator(permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey, captureService: capture, preferencesStore: InMemoryPreferencesStore())
        coordinator.activate()
        defer { coordinator.deactivate() }
        let custom = HotkeyBinding.single(61, "Right Option")
        XCTAssertNil(coordinator.changeHotkey(to: custom))
        XCTAssertEqual(coordinator.registeredHotkey, custom)
        XCTAssertTrue(coordinator.isHotkeySelectionReady)
        XCTAssertTrue(status(coordinator).detail.contains(custom.displayString))
        XCTAssertFalse(status(coordinator).detail.contains("⌥Space"))
        XCTAssertTrue(status(coordinator).showsShortcut)
        coordinator.setActivation(.toggle)
        XCTAssertTrue(status(coordinator).detail.contains("Press"))
        XCTAssertFalse(status(coordinator).detail.contains("Hold"))
        hotkey.emit(.pressed)
        try await waitUntil("toggle recording") { coordinator.state == .recording }
        XCTAssertTrue(status(coordinator).detail.contains(custom.displayString))
        XCTAssertTrue(status(coordinator).detail.contains("again"))
        XCTAssertFalse(status(coordinator).detail.contains("Release"))
        hotkey.emit(.released)
        XCTAssertEqual(coordinator.state, .recording)
        hotkey.emit(.pressed)
        try await waitUntil("toggle finished") { coordinator.state == .ready }
        coordinator.setActivation(.pushToTalk)
        XCTAssertTrue(status(coordinator).detail.contains("Hold"))
        hotkey.emit(.pressed)
        try await waitUntil("hold recording") { coordinator.state == .recording }
        XCTAssertTrue(status(coordinator).detail.contains("Release"))
        hotkey.emit(.released)
        try await waitUntil("hold finished") { coordinator.state == .ready }
    }

    func testRejectedShortcutNeverLeaksIntoThePanelInstruction() {
        let hotkey = FakeHotkeyService()
        let coordinator = DictationCoordinator(permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey, captureService: FakeAudioCaptureService(), preferencesStore: InMemoryPreferencesStore())
        coordinator.activate()
        defer { coordinator.deactivate() }
        let refused = HotkeyBinding(keyCode: 38, modifiers: [.command, .shift], keyLabel: "J")
        hotkey.failNextRegistration(with: HotkeyRegistrationError.alreadyInUse)
        XCTAssertEqual(coordinator.changeHotkey(to: refused), .alreadyInUse)
        XCTAssertEqual(coordinator.registeredHotkey, .optionSpace)
        XCTAssertTrue(status(coordinator).detail.contains(HotkeyBinding.optionSpace.displayString))
        XCTAssertFalse(status(coordinator).detail.contains(refused.displayString))
        coordinator.keepCurrentHotkey()
        XCTAssertTrue(coordinator.isHotkeySelectionReady)
    }

    func testPermissionAndModelFailuresDoNotAdvertiseAReadyShortcut() {
        for state in [RecordingState.needsPermission, .permissionDenied(restricted: false), .failed(.hotkeyRegistration("collision"))] {
            XCTAssertFalse(StatusPresentation(state: state, binding: .optionSpace).showsShortcut)
        }
        for model in [TranscriptionModelState.unavailable("download needed", needsUserAction: true), .failed("no space"), .preparing(ModelPreparation(phase: .downloading, progress: 0.4))] {
            XCTAssertFalse(StatusPresentation(state: .ready, binding: .optionSpace, modelState: model).showsShortcut)
        }
    }

    func testMenuPanelFitsAndExportsBothThemesWithoutPermissionRequests() async throws {
        let folder = URL(fileURLWithPath: "/tmp/witness-glass-preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = FakeTranscriptionService()
        engine.setModelState(.ready)
        let coordinator = DictationCoordinator(permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(), captureService: FakeAudioCaptureService(), transcriptionService: engine,
            preferencesStore: InMemoryPreferencesStore())
        coordinator.activate()
        await coordinator.refreshTranscriptionModelState()
        defer { coordinator.deactivate() }
        let notetaker = MenuNotetakerFixture()
        let files = FileTranscriptionFeature(
            host: coordinator, engine: engine, meetingIsActive: { false },
            store: FileMeetingStore(rootURL: folder.appendingPathComponent("fixture-transcripts"))
        )
        for tab in MenuBarTab.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = MenuBarView(notetaker: notetaker, fileTranscription: files, initialTab: tab)
                    .environmentObject(coordinator).environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: view)
                let size = NSSize(width: 398, height: 680)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                window.contentView = hosting
                hosting.frame = NSRect(origin: .zero, size: size)
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                for _ in 0..<5 { await Task.yield() }
                hosting.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(hosting.fittingSize.width, 399)
                XCTAssertLessThanOrEqual(hosting.fittingSize.height, 681)
                if tab != .files { XCTAssertLessThan(hosting.fittingSize.height, 350, "Idle panel must remain compact") }
                let fitted = hosting.fittingSize
                window.setContentSize(fitted)
                hosting.frame = NSRect(origin: .zero, size: fitted)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent(tab.rawValue + (scheme == .light ? "-light.png" : "-dark.png")))
            }
        }
    }

    func testEveryActiveMeetingStateHasDistinctVisibleStatus() {
        let status = NotetakerStatus()
        var titles = Set<String>()
        for value in [NotetakerActivityState.preparing, .recording, .paused, .finishing, .attention] {
            status.update(value)
            XCTAssertNotNil(status.systemImage)
            XCTAssertFalse(status.activityTitle.isEmpty)
            titles.insert(status.activityTitle)
        }
        XCTAssertEqual(titles.count, 5)
    }
}

@MainActor
private final class MenuNotetakerFixture: NotetakerFacade {
    let status = NotetakerStatus()
    var menuBarItem: NotetakerMenuItem? {
        NotetakerMenuItem(title: "Record meeting note…", systemImage: "note.text.badge.plus", action: {})
    }
    var historyMenuItem: NotetakerMenuItem? {
        NotetakerMenuItem(title: "Meeting note history…", systemImage: "clock.arrow.circlepath", action: {})
    }
    func activate() {}
    func deactivate() {}
}
