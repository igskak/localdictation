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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.application.info("LocalDictation launched as a menu bar utility")
        if let coordinator = Self.coordinator {
            reviewPanel = ReviewPanelController(coordinator: coordinator)
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
        // Last, and detached: the question above is what the user is waiting
        // for, and the sweep is housekeeping nobody is looking at.
        sweepAbandonedModelBundles()
    }

    /// Detached and low priority on purpose: the sweep only ever touches
    /// directories whose owning process is gone, so nothing this launch does —
    /// or any later dictation — waits on it, and deleting the backlog of a long
    /// development day can take a moment.
    private func sweepAbandonedModelBundles() {
        Task.detached(priority: .utility) {
            guard let sweeper = ANEBundleCacheSweeper.forCurrentApp() else { return }
            let outcome = sweeper.sweep()
            guard outcome.removed > 0 else { return }
            let megabytes = outcome.reclaimedBytes / 1_000_000
            Log.transcription.info(
                "Removed \(outcome.removed, privacy: .public) abandoned model bundles, \(megabytes, privacy: .public) MB"
            )
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
