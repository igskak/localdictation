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
        let hosting = NSHostingView(rootView: SettingsView(updater: AppUpdater(startingUpdater: false)).environmentObject(coordinator))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
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

    func testSecondaryAndWarningTextKeepReadableContrastInBothAppearances() throws {
        func luminance(_ color: NSColor) throws -> Double {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: [(NSColor, NSColor)] = []
            appearance.performAsCurrentDrawingAppearance {
                resolved = [
                    (NSColor(WitnessStyle.muted), NSColor(WitnessStyle.surface)),
                    (NSColor(WitnessStyle.muted), NSColor(WitnessStyle.canvas)),
                    (NSColor(WitnessStyle.warning), NSColor(WitnessStyle.surface)),
                    (.white, NSColor(WitnessStyle.actionFill)),
                ]
                // Resolve dynamic colors while the tested appearance is current.
                resolved = resolved.compactMap { foreground, background in
                    guard let fg = foreground.usingColorSpace(.sRGB), let bg = background.usingColorSpace(.sRGB) else { return nil }
                    return (fg, bg)
                }
            }
            XCTAssertEqual(resolved.count, 4)
            for (foreground, background) in resolved {
                let first = try luminance(foreground), second = try luminance(background)
                XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 4.5, name.rawValue)
            }
        }
    }

    func testTheSettingsWindowLaysOutWithDefaults() async throws {
        let size = render(makeCoordinator())

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        try await settle()
    }

    func testTheSettingsWindowLaysOutInTheExpansionLocales() async throws {
        for identifier in ["es", "it", "fr"] {
            let coordinator = makeCoordinator()
            let hosting = NSHostingView(
                rootView: SettingsView(updater: AppUpdater(startingUpdater: false))
                    .environmentObject(coordinator)
                    .environment(\.locale, Locale(identifier: identifier))
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            hosting.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(hosting.fittingSize.height, 0, identifier)
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, 900, identifier)
            hosting.removeFromSuperview()
            try await settle()
        }
    }

    func testEverySettingsSectionFitsInBothAppearancesAndAllInterfaceLanguages() {
        let coordinator = makeCoordinator()
        defer { coordinator.deactivate() }
        let updater = AppUpdater(startingUpdater: false)
        for locale in ["en", "de", "es", "it", "fr"] {
            for scheme in [ColorScheme.light, .dark] {
                for section in SettingsSection.allCases {
                    let hosting = NSHostingView(rootView:
                        SettingsView(initialSelection: section, updater: updater)
                            .environmentObject(coordinator)
                            .environment(\.locale, Locale(identifier: locale))
                            .environment(\.colorScheme, scheme)
                    )
                    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
                    hosting.layoutSubtreeIfNeeded()
                    let context = "\(locale), \(scheme), \(section.rawValue)"
                    XCTAssertLessThanOrEqual(hosting.fittingSize.width, 900, context)
                    XCTAssertLessThanOrEqual(hosting.fittingSize.height, 700, context)
                    hosting.removeFromSuperview()
                }
            }
        }
    }

    /// Captures real SwiftUI views using in-memory stores and a stopped update
    /// scheduler, without using a microphone or starting a model download.
    func testExportRedesignedSettingsPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("witness-ui-refresh-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = makeCoordinator()
        defer { coordinator.deactivate() }
        let updater = AppUpdater(startingUpdater: false)
        for (section, scheme, name) in [
            (SettingsSection.dictation, ColorScheme.light, "settings-light"),
            (.dictation, .dark, "settings-dark"),
            (.speechModel, .light, "speech-model-light"),
            (.speechModel, .dark, "speech-model-dark"),
            (.cleanup, .light, "cleanup-light"),
            (.privacy, .light, "privacy-light"),
        ] {
            let hosting = NSHostingView(rootView:
                SettingsView(initialSelection: section, updater: updater)
                    .environmentObject(coordinator)
                    .environment(\.colorScheme, scheme)
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            hosting.layoutSubtreeIfNeeded()
            try await settle()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            window.close()
        }
    }

    func testBoundaryAndDiagnosticsLayOutInTheExpansionLocales() async throws {
        for identifier in ["es", "it", "fr"] {
            let coordinator = makeCoordinator()
            let views = [
                AnyView(BoundarySettingsView().environmentObject(coordinator)),
                AnyView(DiagnosticsView().environmentObject(coordinator)),
            ]

            for view in views {
                let hosting = NSHostingView(
                    rootView: view
                        .frame(width: 680, height: 540)
                        .environment(\.locale, Locale(identifier: identifier))
                )
                hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 540)
                hosting.layoutSubtreeIfNeeded()

                XCTAssertGreaterThan(hosting.fittingSize.height, 0, identifier)
                XCTAssertLessThanOrEqual(hosting.fittingSize.width, 700, identifier)
                hosting.removeFromSuperview()
                try await settle()
            }
        }
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

    func testTheMenuLaysOutInTheExpansionLocales() async throws {
        for identifier in ["es", "it", "fr"] {
            let coordinator = makeCoordinator(
                secureInput: SecureInputState(isEnabled: true, holderName: "1Password")
            )
            let hosting = NSHostingView(
                rootView: MenuBarView()
                    .environmentObject(coordinator)
                    .environment(\.locale, Locale(identifier: identifier))
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 700)
            hosting.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(hosting.fittingSize.height, 0, identifier)
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, 400, identifier)
            hosting.removeFromSuperview()
            try await settle()
        }
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

    func testExpandedRecentDictationsHaveAVisibleViewport() {
        let items = (1...3).map { RecentDictation(text: "A previous dictation number \($0)") }
        let collapsed = renderRecentDictations(items, expanded: false)
        let expanded = renderRecentDictations(items, expanded: true)

        XCTAssertGreaterThan(
            expanded.height,
            collapsed.height + 150,
            "The expanded history must reserve visible height for its rows."
        )
    }

    private func renderRecentDictations(_ items: [RecentDictation], expanded: Bool) -> NSSize {
        let hosting = NSHostingView(
            rootView: RecentDictationsView(items: items, initiallyExpanded: expanded)
                .frame(width: 336)
        )
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.removeFromSuperview()
        return size
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
