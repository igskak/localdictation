import AppKit
import Combine
import SwiftUI

/// Shows the review, and the small thing that offers it.
///
/// Phase 3 put the review strip inside the menu bar window, which the user
/// opens by clicking. Phase 4 moved it in front of the document, because the
/// click that opens a menu bar window moves focus out of the field the text is
/// going into — and the caret is the insertion point.
///
/// Phase 5 takes the last thing it was doing away from it: standing in the way.
/// The strip no longer appears on its own and no longer authorizes anything.
/// What appears is a chip that says how many fragments are worth a look and
/// then fades; the strip opens only if someone asks for it, from the chip or
/// from the menu.
///
/// Both panels are `.nonactivatingPanel`: they take clicks without activating
/// LocalDictation, the target application stays frontmost, and the caret stays
/// where the user left it. The alternative — activate, then restore focus
/// afterwards — was rejected in `docs/PHASE_4.md`: restoring focus across
/// Electron and browser fields is unreliable, and not taking it is a smaller
/// mechanism than putting it back.
@MainActor
final class ReviewPanelController {
    /// How long the aftermath panel stays up.
    ///
    /// Two durations because it carries two kinds of thing. A sentence about
    /// where the text went has to be read to be useful, so it gets six seconds.
    /// A chip offering a review is a glance — three is enough to notice it, and
    /// the menu bar triangle stays lit behind it for anyone who looks up later.
    private static let noticeDuration = Duration.seconds(6)
    private static let chipDuration = Duration.seconds(3)

    private let coordinator: DictationCoordinator
    private var panel: NSPanel?
    /// Held as a plain view: only its fitting size is ever read, and the
    /// environment object makes the hosted root's type unspellable anyway.
    private var hostingView: NSView?
    private var noticePanel: NSPanel?
    private var noticeHostingView: NSHostingView<AftermathView>?
    private var noticeDismissal: Task<Void, Never>?
    private var visibilityObserver: AnyCancellable?
    private var outcomeObserver: AnyCancellable?
    private var attentionObserver: AnyCancellable?
    private var silenceObserver: AnyCancellable?
    private var contentObserver: AnyCancellable?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        visibilityObserver = coordinator.$isShowingReview
            .removeDuplicates()
            .sink { [weak self] isShowing in
                // The published value arrives before the property is updated,
                // so the panel is built on the next turn of the loop with the
                // coordinator already consistent.
                Task { @MainActor in self?.apply(isShowing: isShowing) }
            }
        outcomeObserver = coordinator.$lastInsertion
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.presentAftermath() }
            }
        attentionObserver = coordinator.$attentionIsPending
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.presentAftermath() }
            }
        // The press that produced nothing. It reaches the same panel as a
        // clipboard fallback because it is the same kind of thing: the one
        // sentence the app owes the user when the words did not appear where
        // they were typing, said where they are already looking rather than in
        // a menu they have no reason to open.
        silenceObserver = coordinator.$silentResult
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.presentAftermath() }
            }
        // The one thing that changes the panel's height while it is open.
        // A new result does not: it arrives with a state change, which shows
        // the panel again and measures it then.
        contentObserver = coordinator.$prefersRawTranscript
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.resizeToContent() }
            }
    }

    #if DEBUG
    /// Read by the tests that drive a real panel through a real layout pass.
    var isShowingReviewPanel: Bool { panel?.isVisible ?? false }
    var reviewPanelContentSize: NSSize? { panel?.contentView?.frame.size }
    var isShowingNotice: Bool { noticePanel?.isVisible ?? false }
    #endif

    private func apply(isShowing: Bool) {
        if isShowing {
            // One thing at a time in the same corner of the screen: the chip's
            // whole job was to get the review opened.
            hideNotice()
            show()
        } else {
            hide()
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel, toFit: hostingView)
        position(panel)
        // Deliberately not `makeKeyAndOrderFront`: taking key status is what a
        // non-activating panel exists to avoid.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func resizeToContent() {
        guard let panel, panel.isVisible else { return }
        resize(panel, toFit: hostingView)
        position(panel)
    }

    /// Sizes a panel to its SwiftUI content, once, from outside the layout pass.
    ///
    /// The first version let `NSHostingController.sizingOptions` do this and
    /// forced a layout pass while positioning the window. That is a loop:
    /// resizing the window makes SwiftUI lay out again, which produces a new
    /// preferred size, which resizes the window — until AppKit gives up with
    /// "more Update Constraints passes than there are views in the window" and
    /// takes the app down with it.
    ///
    /// So nothing resizes the window except this method, it is only ever called
    /// from an event handler rather than from inside layout, and it does
    /// nothing when the size has not actually changed.
    /// The size is rounded to whole points and compared with a tolerance rather
    /// than for equality. `fittingSize` is fractional whenever the content is —
    /// one SF Symbol with a half-point intrinsic height is enough — while the
    /// frame a window settles on is backing-aligned, so an exact comparison
    /// between the two can never be true. The guard then never fires and the
    /// loop above is reached by a different road.
    ///
    /// This is a floor, not the whole defence: it narrows the gap but does not
    /// close it, and content whose measured height genuinely oscillates will
    /// still defeat it. Views in this panel keep their measurements integral —
    /// see the pinned icon frame in `ReviewStripView.header`.
    private func resize(_ panel: NSPanel, toFit view: NSView?) {
        guard let view else { return }
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }

        let size = NSSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        if let current = panel.contentView?.frame.size,
           abs(current.width - size.width) < 1,
           abs(current.height - size.height) < 1 {
            return
        }
        panel.setContentSize(size)
    }

    // MARK: - Outcome notice

    /// Says what is left to say once the text has gone.
    ///
    /// One panel for two messages, because they land in the same corner at the
    /// same moment and two panels would draw on top of each other. It carries
    /// where the text went when that was not where it was meant to go, and an
    /// offer to check the fragments the risk engine flagged — either, both, or
    /// neither, in which case nothing appears.
    ///
    /// A successful insertion with nothing flagged says nothing at all. The
    /// text appearing in the document is the message, and a panel congratulating
    /// the app on it would be noise on the path this phase exists to keep quiet.
    ///
    /// Without this the quiet path could fail quietly: the words do not appear,
    /// no window opens, and the only explanation sits in a menu the user has no
    /// reason to open. A clipboard fallback is an acceptable result exactly
    /// because it is an *explained* one.
    private func presentAftermath() {
        noticeDismissal?.cancel()

        // At most one of these can be set: an empty result never reaches an
        // insertion, and an insertion outcome only exists where there was text.
        let message = coordinator.lastInsertion?.message ?? coordinator.silentResult?.message
        let attention = coordinator.attentionIsPending ? coordinator.result?.flaggedSpans.count ?? 0 : 0
        guard message != nil || attention > 0 else {
            hideNotice()
            return
        }
        // The review is already open; the chip would be offering what the user
        // is looking at.
        guard !coordinator.isShowingReview else { return }

        let panel = noticePanel ?? makeNoticePanel()
        noticePanel = panel
        noticeHostingView?.rootView = makeAftermathView(message: message, flaggedCount: attention)
        resize(panel, toFit: noticeHostingView)
        position(panel)
        panel.orderFrontRegardless()

        // The chip fades on its own but the indicator does not: the menu bar
        // triangle stays lit until the user opens the review or puts it out.
        // Fading is the app being quiet, not the app forgetting.
        let duration = message == nil ? Self.chipDuration : Self.noticeDuration
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hideNotice()
        }
    }

    private func makeAftermathView(message: String?, flaggedCount: Int) -> AftermathView {
        AftermathView(
            message: message,
            flaggedCount: flaggedCount,
            check: { [weak self] in
                self?.hideNotice()
                self?.coordinator.openReview()
            },
            dismiss: { [weak self] in
                self?.hideNotice()
                self?.coordinator.dismissAttention()
                self?.coordinator.dismissSilentResult()
            }
        )
    }

    private func hideNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        noticePanel?.orderOut(nil)
    }

    private func makeNoticePanel() -> NSPanel {
        let panel = makeBarePanel(width: 444)
        let hosting = NSHostingView(rootView: makeAftermathView(message: nil, flaggedCount: 0))
        panel.contentView = hosting
        noticeHostingView = hosting
        return panel
    }

    private func makePanel() -> NSPanel {
        let panel = makeBarePanel(width: 484)
        // An `NSHostingView` rather than a controller with `sizingOptions`:
        // the controller resizes its window from inside the layout pass, and
        // this panel is positioned from outside it. See `resize(_:toFit:)`.
        let hosting = NSHostingView(rootView: ReviewPanelView().environmentObject(coordinator))
        panel.contentView = hosting
        hostingView = hosting
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
            if let result = coordinator.result, result.hasAnythingToReview {
                ReviewStripView(result: result)
            } else {
                // Between closing the review and the panel going away. Never
                // shown for longer than one turn of the run loop.
                Color.clear.frame(width: 460, height: 1)
            }
        }
        .frame(width: 460)
        .padding(12)
    }
}

/// What is left to say once the text is already in the document.
///
/// Deliberately small and deliberately optional. The triangle is an offer, not
/// a verdict: the app has no idea whether "1450" is wrong, only that it is the
/// kind of thing that is worth a second of the user's own judgement. So the
/// wording counts fragments and says nothing about correctness, and the
/// primary action is the one that costs nothing — leaving.
struct AftermathView: View {
    let message: String?
    let flaggedCount: Int
    let check: () -> Void
    let dismiss: () -> Void

    private var attentionText: String {
        flaggedCount == 1 ? "1 fragment worth checking" : "\(flaggedCount) fragments worth checking"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
            }

            if flaggedCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(attentionText)
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button("Check", action: check)
                }
            }

            HStack {
                Spacer()
                Button(flaggedCount > 0 ? "Not now" : "OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 420, alignment: .leading)
        .padding(12)
    }
}
