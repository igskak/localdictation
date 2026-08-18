import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `LocalDictationApp` during scene construction so the delegate can
    /// drive launch, activation, and termination hooks.
    static weak var coordinator: DictationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.application.info("LocalDictation launched as a menu bar utility")
        Self.coordinator?.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.coordinator?.refreshAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.coordinator?.deactivate()
    }
}
