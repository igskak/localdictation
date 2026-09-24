import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// The small, click-through acknowledgement beside the place being dictated into.
/// It never becomes key and never inserts placeholder characters into another app.
enum DictationActivity: Equatable {
    case recording
    case processing

    init?(state: RecordingState) {
        switch state {
        case .recording:
            self = .recording
        case .finishing, .transcribing, .inserting:
            self = .processing
        default:
            return nil
        }
    }
}

@MainActor
protocol TextCaretLocating {
    /// Screen rectangle only. No field value or selected text is read.
    func caretRect(for processIdentifier: pid_t) -> CGRect?
}

@MainActor
struct AccessibilityTextCaretLocator: TextCaretLocating {
    func caretRect(for processIdentifier: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.15)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range) else { return nil }
        // For a selection, the words would land at its end. A zero-length
        // range is the ordinary insertion point.
        range.location += range.length
        range.length = 0
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &boundsValue
        ) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(boundsValue, to: AXValue.self), .cgRect, &bounds),
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite else { return nil }
        return bounds
    }
}

@MainActor
final class DictationActivityPanelController {
    private static let size = NSSize(width: 100, height: 28)
    private let coordinator: DictationCoordinator
    private let caretLocator: any TextCaretLocating
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DictationActivityView>?
    private var stateObserver: AnyCancellable?
    private var anchor: NSPoint?

    init(coordinator: DictationCoordinator, caretLocator: any TextCaretLocating = AccessibilityTextCaretLocator()) {
        self.coordinator = coordinator
        self.caretLocator = caretLocator
        stateObserver = coordinator.$state
            .removeDuplicates()
            .sink { [weak self] state in
                // `@Published` publishes before `coordinator.state` and the
                // captured target have settled. Use the next main-actor turn.
                Task { @MainActor in self?.update(for: state) }
            }
    }

    #if DEBUG
    var isVisible: Bool { panel?.isVisible ?? false }
    var passesClicksThrough: Bool { panel?.ignoresMouseEvents ?? false }
    #endif

    private func update(for state: RecordingState) {
        guard state == coordinator.state else { return }
        guard let activity = DictationActivity(state: state) else {
            panel?.orderOut(nil)
            anchor = nil
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        if anchor == nil { anchor = locateAnchor() }
        hostingView?.rootView = DictationActivityView(activity: activity)
        let fallback = NSEvent.mouseLocation
        position(panel, at: anchor ?? NSPoint(x: fallback.x + 12, y: fallback.y + 12))
        panel.orderFrontRegardless()
    }

    private func locateAnchor() -> NSPoint? {
        guard let processIdentifier = coordinator.activityTargetProcessIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let bounds = caretLocator.caretRect(for: processIdentifier),
              let primary = NSScreen.screens.first else { return nil }

        // Accessibility reports screen rectangles from the top-left of the
        // primary display; AppKit's global window coordinates grow upward.
        let caret = NSPoint(x: bounds.maxX, y: primary.frame.maxY - bounds.minY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(caret) }) else { return nil }
        let x = caret.x + Self.size.width + 10 <= screen.visibleFrame.maxX
            ? caret.x + 10
            : bounds.minX - Self.size.width - 10
        // Above the text line so the badge does not cover the words the user
        // is watching. The clamp below handles fields near the screen edge.
        return NSPoint(x: x, y: caret.y + 6)
    }

    private func position(_ panel: NSPanel, at point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.size
        // Keep the badge out of the menu bar, Dock, and neighbouring displays.
        let x = min(max(point.x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = min(max(point.y, visible.minY + 6), visible.maxY - size.height - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let hosting = NSHostingView(rootView: DictationActivityView(activity: .recording))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        hostingView = hosting
        return panel
    }
}

private struct DictationActivityView: View {
    let activity: DictationActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.42, paused: reduceMotion)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.42) % 3
            HStack(spacing: 6) {
                switch activity {
                case .recording:
                    Circle()
                        .fill(WitnessStyle.accent)
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion || phase == 0 ? 1 : 0.55)
                    Text(L10n.string("Recording"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WitnessStyle.ink)
                case .processing:
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(WitnessStyle.ink)
                                .frame(width: 5, height: 5)
                                .opacity(reduceMotion || phase == index ? 0.95 : 0.35)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 100, height: 28)
            .background(WitnessStyle.surface.opacity(0.96), in: Capsule())
            .overlay { Capsule().stroke(WitnessStyle.strongLine, lineWidth: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity == .recording ? L10n.string("Recording") : L10n.string("Transcribing"))
    }
}
