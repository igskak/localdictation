import AppKit
import SwiftUI

/// The window a refused hotkey press opens.
///
/// Until this existed, the whole licensing wall lived in two places a locked
/// user does not necessarily look: the menu, which they have to think to open,
/// and Settings, which they have to think to open twice. What a stranger
/// actually did was press the hotkey, get nothing, press it again, get nothing,
/// and conclude the app was broken — and the app being broken and the app
/// asking for an email address look identical when neither of them says
/// anything.
///
/// So this is not a paywall that appears on a timer or on launch. It appears
/// when, and only when, a person pressed the key and licensing said no. That
/// makes it an answer to a question they asked one second earlier, which is the
/// difference between a dialog and an interruption.
///
/// It is deliberately the same surface as Settings → License rather than a
/// second, shorter version of it. There are three things a locked user might
/// want — start the trial, fetch a key they already bought, or paste one from
/// an email — and which one they want is not knowable from here. A window that
/// guessed would be right two thirds of the time.
@MainActor
final class ActivationWindowController: NSObject, NSWindowDelegate {
    private let coordinator: DictationCoordinator
    private(set) var window: NSWindow?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    /// Brings the window up, or forward if it is already there.
    ///
    /// Safe to call on every refused press. A second press while the window is
    /// open does not build a second window, and it does not steal focus from a
    /// field the user is typing an address into — `makeKeyAndOrderFront` on a
    /// window that is already key is a no-op.
    func present() {
        guard coordinator.entitlement.lock != nil else { return }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalDictation"
        window.contentView = NSHostingView(
            rootView: ActivationWindowView()
                .environmentObject(coordinator)
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        // The same two lines `LanguageSetupWindowController` needs, for the same
        // reason: an accessory app has no Dock icon to bounce, and a window that
        // opens behind a full-screen editor is a window nobody was shown.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        self.window = window

        Log.licensing.info("Showing the activation window after a refused press")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes itself the moment the Mac is entitled again, so the successful
    /// path ends with the user back where they were rather than with a window
    /// they have to dismiss to find out whether it worked.
    func dismissIfEntitled() {
        guard coordinator.entitlement.lock == nil else { return }
        window?.close()
    }

    var isPresenting: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// The window's contents: one sentence about why nothing happened, and then the
/// whole License page.
private struct ActivationWindowView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            LicenseView()
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("That press did not start a recording")
                    .font(.headline)
                Text(
                    "Nothing was recorded and nothing was lost. Everything below is on this Mac already — "
                        + "your dictionary, your settings, and every word you have dictated."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
