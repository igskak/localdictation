import AppKit
import Combine
import SwiftUI

/// Shows the review in a panel that does not take focus.
///
/// Phase 3 put the review strip inside the menu bar window, which the user
/// opens by clicking. That was right while the strip was the destination. From
/// Phase 4 it stands between the user and their own document, and the click
/// that opens a menu bar window moves focus out of the field the text is going
/// into — which is the one thing this phase cannot afford, because the caret is
/// the insertion point.
///
/// So the panel is `.nonactivatingPanel`: it takes clicks without activating
/// LocalDictation, the target application stays frontmost, and the caret stays
/// where the user left it. The alternative — activate, then restore focus
/// afterwards — was rejected in `docs/PHASE_4.md`: restoring focus across
/// Electron and browser fields is unreliable, and not taking it is a smaller
/// mechanism than putting it back.
@MainActor
final class ReviewPanelController {
    /// How long an outcome notice stays up. Long enough to read a sentence,
    /// short enough that it is gone before the next dictation.
    private static let noticeDuration = Duration.seconds(6)

    private let coordinator: DictationCoordinator
    private var panel: NSPanel?
    private var noticePanel: NSPanel?
    private var noticeDismissal: Task<Void, Never>?
    private var stateObserver: AnyCancellable?
    private var outcomeObserver: AnyCancellable?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        stateObserver = coordinator.$state
            .removeDuplicates()
            .sink { [weak self] state in
                // The published value arrives before the property is updated,
                // so the panel is built on the next turn of the loop with the
                // coordinator already consistent.
                Task { @MainActor in self?.apply(state) }
            }
        outcomeObserver = coordinator.$lastInsertion
            .removeDuplicates()
            .sink { [weak self] outcome in
                Task { @MainActor in self?.present(outcome) }
            }
    }

    private func apply(_ state: RecordingState) {
        if state.isReviewing {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        // Deliberately not `makeKeyAndOrderFront`: taking key status is what a
        // non-activating panel exists to avoid.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Outcome notice

    /// Says where the text went when it did not go where it was meant to.
    ///
    /// Without this the quiet path can fail quietly: the words do not appear,
    /// no window opens, and the only explanation sits in a menu the user has no
    /// reason to open. A clipboard fallback is an acceptable result exactly
    /// because it is an *explained* one.
    ///
    /// Never shown for a successful insertion. The text appearing in the
    /// document is the message, and a panel congratulating the app on it would
    /// be noise on the path this phase exists to keep quiet.
    private func present(_ outcome: InsertionOutcome?) {
        noticeDismissal?.cancel()
        guard let message = outcome?.message else {
            hideNotice()
            return
        }

        let panel = noticePanel ?? makeNoticePanel()
        noticePanel = panel
        (panel.contentViewController as? NSHostingController<InsertionNoticeView>)?
            .rootView = InsertionNoticeView(message: message) { [weak self] in self?.hideNotice() }
        position(panel)
        panel.orderFrontRegardless()

        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.hideNotice()
        }
    }

    private func hideNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        noticePanel?.orderOut(nil)
    }

    private func makeNoticePanel() -> NSPanel {
        let panel = makeBarePanel(width: 420)
        let controller = NSHostingController(
            rootView: InsertionNoticeView(message: "") { [weak self] in self?.hideNotice() }
        )
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        return panel
    }

    private func makePanel() -> NSPanel {
        let panel = makeBarePanel(width: 460)
        let controller = NSHostingController(rootView: ReviewPanelView().environmentObject(coordinator))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        return panel
    }

    /// The window settings both panels share, and the reason either exists:
    /// visible over anything, clickable without activating this app.
    private func makeBarePanel(width: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // People write in full screen, and a review the user cannot see is a
        // review that silently blocks their text.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// Top centre of the screen the pointer is on, under the menu bar.
    ///
    /// Not at the caret: finding it means reading the target's layout through
    /// Accessibility, it is missing or wrong in exactly the applications that
    /// need the fallback most, and a panel that lands in the wrong place is
    /// worse than one that is always in the same place.
    private func position(_ panel: NSPanel) {
        // The hosting controller sizes the window from its content, but only
        // once that content has laid out. Measuring before it does gives a
        // collapsed panel placed against the wrong edge.
        panel.contentViewController?.view.layoutSubtreeIfNeeded()

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 12
            )
        )
    }
}

/// The panel's contents: the review strip, and nothing else.
private struct ReviewPanelView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        Group {
            if let result = coordinator.result, result.requiresReview {
                ReviewStripView(result: result)
            } else {
                // Between the decision and the panel closing. Never shown for
                // longer than one turn of the run loop.
                Color.clear.frame(width: 460, height: 1)
            }
        }
        .frame(width: 460)
        .padding(12)
    }
}

/// One sentence about where the text went, and a way to dismiss it.
private struct InsertionNoticeView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("OK", action: dismiss)
        }
        .frame(width: 420, alignment: .leading)
        .padding(12)
    }
}
