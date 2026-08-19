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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.application.info("LocalDictation launched as a menu bar utility")
        if let coordinator = Self.coordinator {
            reviewPanel = ReviewPanelController(coordinator: coordinator)
        }
        Self.coordinator?.activate()
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
