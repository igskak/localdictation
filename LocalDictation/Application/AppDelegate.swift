import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `LocalDictationApp` during scene construction so the delegate can
    /// drive launch, activation, and termination hooks.
    static weak var coordinator: DictationCoordinator?

    /// Owns the floating review panel for the lifetime of the app. It has to
    /// live somewhere outside the menu bar scene: the review has to be able to
    /// appear while the user is in another application and has not clicked
    /// anything of ours.
    private var reviewPanel: ReviewPanelController?

    /// Owns the first-run language question. Nil once it has been answered,
    /// which for a returning user is before the app ever runs.
    private var languageSetup: LanguageSetupWindowController?

    /// Owns the window a refused hotkey press opens. Like the review panel, it
    /// has to live outside the menu bar scene: it appears while the user is in
    /// another application and has clicked nothing of ours.
    private var activation: ActivationWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.application.info("LocalDictation launched as a menu bar utility")
        if let coordinator = Self.coordinator {
            reviewPanel = ReviewPanelController(coordinator: coordinator)

            // The one thing a locked user reliably does is press the hotkey, so
            // that press is where the app answers. Wired before `activate`, so
            // a press cannot arrive with nowhere to go.
            let activation = ActivationWindowController(coordinator: coordinator)
            self.activation = activation
            coordinator.onDictationRefusedByLicensing = { [weak activation] in
                activation?.present()
            }
            coordinator.onEntitlementChanged = { [weak activation] _ in
                activation?.dismissIfEntitled()
            }
        }
        Self.coordinator?.activate()
        // After `activate`, which is what reads the settings file: whether the
        // question has been answered is a fact from disk, not an assumption
        // about how new this installation is.
        if let coordinator = Self.coordinator, coordinator.needsLanguageSetup {
            let setup = LanguageSetupWindowController(coordinator: coordinator)
            languageSetup = setup
            setup.presentIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Also how the app notices Accessibility trust: it is granted in System
        // Settings, out of band, and macOS sends no notification when it
        // changes. Coming back to the app is the moment to re-read it.
        Self.coordinator?.refreshAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.coordinator?.deactivate()
    }
}
