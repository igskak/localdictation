import AppKit
import SwiftUI

/// The window that carries the first-run language question.
///
/// A real window rather than one of `ReviewPanelController`'s non-activating
/// panels, and for the opposite reason: those exist so the caret never leaves
/// the document, and this one exists to be answered. The app is an accessory
/// with no Dock icon, so it has to activate itself to be seen at all.
///
/// Only the Continue button answers the question. Closing the window means
/// "not now", and the question comes back at the next launch.
///
/// This was the other way round for exactly one live launch, on the reasoning
/// that the app has always had a profile so there was nothing to cancel into.
/// What that missed is that a window can be closed without ever having been
/// read — behind another window, on another Space, or by a person clearing
/// their screen. It recorded German and English, which the user had never
/// chosen, and then never asked again. A question that can be answered by
/// accident is not a question.
@MainActor
final class LanguageSetupWindowController: NSObject, NSWindowDelegate {
    private let coordinator: DictationCoordinator
    private let model: LanguageSetupModel
    private let loginItem: any LoginItemService
    /// Internal so the tests that drive this can close it the way a user does,
    /// rather than hunting for it in `NSApp.windows`.
    private(set) var window: NSWindow?
    /// Set the moment the answer is recorded, so closing the window afterwards
    /// is not mistaken for the question going unanswered.
    private var isAnswered = false

    /// The login item is passed in rather than made here: the real one writes to
    /// the machine's login items, and a test that closed this window would
    /// register the test host.
    init(coordinator: DictationCoordinator, loginItem: any LoginItemService) {
        self.coordinator = coordinator
        self.loginItem = loginItem
        model = LanguageSetupModel(selection: coordinator.languageProfile)
        super.init()
    }

    /// Shows the first run, if the question has not been answered.
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
        window.title = "Witness"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 17 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: FirstRunView(
                model: model,
                coordinator: coordinator,
                confirm: { [weak self] in self?.confirmSelection() },
                finish: { [weak self] in self?.finish() }
            )
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Above other applications, and on whichever Space the user is
        // actually looking at. An accessory app has no Dock icon to bounce and
        // no window of its own to come forward with: without these, the one
        // question this app ever asks can open behind a full-screen editor and
        // be closed by someone tidying their screen.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        self.window = window

        Log.application.info("Asking which languages the user speaks")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// What the Continue button does, and the only thing that answers the
    /// question. Internal so a test can press it without a click.
    ///
    /// It does not close the window. The answer is recorded and the window moves
    /// on to the half of the first run that used to be missing entirely — what
    /// the hotkey is, what macOS will ask for, and what happens after the fifth
    /// dictation.
    func confirmSelection() {
        guard !isAnswered else { return }
        isAnswered = true
        coordinator.completeLanguageSetup(with: model.selection)
        model.step = .ready
    }

    /// The end of the first run. Closing the window by hand does the same
    /// thing — nothing here is a second question, so nothing here can be left
    /// unanswered.
    func finish() {
        window?.close()
    }

    /// Flips the second screen's switch the way a click does, for tests that
    /// have no way to click it.
    func setOpensAtLoginForTesting(_ opens: Bool) { model.opensAtLogin = opens }

    /// Whether the question is on screen. The second screen is not a question,
    /// so it does not count as asking one.
    var isAsking: Bool { window?.isVisible == true && model.step == .languages }

    /// Whether the window is up at all, in either of its two states.
    var isPresenting: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        window = nil
        guard !isAnswered else {
            applyLoginChoice()
            return
        }
        // Nothing is recorded, so `needsLanguageSetup` stays true and the next
        // launch asks again. Logged because "why am I being asked twice" and
        // "why was I never asked" are the same question from opposite sides.
        Log.application.notice("Language question closed without an answer; it will be asked again")
    }

    /// Opens the app at login, unless the person switched that off on the
    /// second screen.
    ///
    /// Here and not when the question is answered, so the switch on the second
    /// screen is a choice that has not happened yet rather than something to
    /// undo, and macOS's own "background item added" notice does not land on top
    /// of the microphone and Accessibility prompts.
    ///
    /// Only from `.disabled`. An item the user already switched off in System
    /// Settings (`.requiresApproval`) is an answer, and registering again would
    /// overrule it; one that is already `.enabled` needs nothing; `.unavailable`
    /// is a build macOS will not register, which Settings explains. A refusal is
    /// not shown here, because the second screen has already closed.
    ///
    /// This is a first-run default only. A Mac that has answered the language
    /// question never reaches it, so nobody who installed before is changed.
    private func applyLoginChoice() {
        guard model.opensAtLogin, loginItem.state == .disabled else { return }
        let result = loginItem.setEnabled(true)
        Log.application.info("Open at login offered at first run: \(String(describing: result), privacy: .public)")
    }
}
