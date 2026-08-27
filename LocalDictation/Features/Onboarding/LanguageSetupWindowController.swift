import AppKit
import SwiftUI

/// The window that carries the first-run language question.
///
/// A real window rather than one of `ReviewPanelController`'s non-activating
/// panels, and for the opposite reason: those exist so the caret never leaves
/// the document, and this one exists to be answered. The app is an accessory
/// with no Dock icon, so it has to activate itself to be seen at all.
///
/// Closing the window records the selection on screen. There is no cancel,
/// because there is nothing to cancel into — the app has always had a language
/// profile, and this question is about replacing a default nobody chose with an
/// answer somebody gave.
@MainActor
final class LanguageSetupWindowController: NSObject, NSWindowDelegate {
    private let coordinator: DictationCoordinator
    private let model: LanguageSetupModel
    /// Internal so the tests that drive this can close it the way a user does,
    /// rather than hunting for it in `NSApp.windows`.
    private(set) var window: NSWindow?
    /// Set the moment the answer is recorded, so the window delegate cannot
    /// record it a second time as the window closes.
    private var isFinished = false

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        model = LanguageSetupModel(selection: coordinator.languageProfile)
        super.init()
    }

    /// Shows the question, if it has not been answered.
    ///
    /// Safe to call more than once: a second call while the window is up brings
    /// it forward rather than building another one.
    func presentIfNeeded() {
        guard coordinator.needsLanguageSetup else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Languages"
        window.contentView = NSHostingView(
            rootView: LanguageSetupView(model: model) { [weak self] in self?.finish() }
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        Log.application.info("Asking which languages the user speaks")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        coordinator.completeLanguageSetup(with: model.selection)
        window?.close()
        window = nil
    }

    /// Whether the question is on screen.
    var isAsking: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        // The red button is an answer too: the selection on screen is the one
        // the user has been looking at, and re-asking at the next launch would
        // be the app taking a decision back.
        finish()
    }
}
