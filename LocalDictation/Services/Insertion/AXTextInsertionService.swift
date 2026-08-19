import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The live insertion path: Accessibility first, synthetic paste second,
/// clipboard third, and a refusal where dictation does not belong.
///
/// The order is `docs/PHASE_4.md`'s, and so is the reason for it. Writing into
/// the focused element involves no clipboard and no synthetic events, and the
/// target's own undo usually reverses it in one step. Pasting is what remains
/// where an element is not exposed or not settable — much of Electron, some web
/// fields. The clipboard is what remains after that, and it is a result rather
/// than a failure.
///
/// Everything here runs on the main actor and synchronously, apart from the one
/// genuine wait in the paste path. Accessibility calls to a responsive
/// application return in well under a millisecond; the messaging timeout bounds
/// the case where the target has hung, which is a state the user's Mac is
/// already visibly in.
@MainActor
final class AXTextInsertionService: TextInsertionService {
    /// How long an Accessibility call to another process may take before it is
    /// abandoned. Half a second is far above a healthy round trip and far below
    /// what reads as a freeze.
    private static let messagingTimeout: Float = 0.5

    /// How long the target application is given to read the pasteboard before
    /// the previous contents go back. Long enough for the applications in the
    /// compatibility matrix, short enough that the user's clipboard is not
    /// ours for any noticeable time.
    private static let pasteSettlingDelay = Duration.milliseconds(200)

    private let permissionService: any AccessibilityPermissionService
    private let pasteboard: any Pasteboard

    /// The focused element captured together with the most recent target.
    ///
    /// One entry, not a table: only the newest recording can be inserted, and
    /// keeping older references alive would keep other applications' UI objects
    /// alive with them.
    private var capturedElement: (targetID: UUID, element: AXUIElement)?

    init(
        permissionService: any AccessibilityPermissionService = AXAccessibilityPermissionService(),
        pasteboard: any Pasteboard = SystemPasteboard()
    ) {
        self.permissionService = permissionService
        self.pasteboard = pasteboard
    }

    // MARK: - Capture

    func captureTarget() -> InsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            capturedElement = nil
            return nil
        }
        // Dictating with our own window in front means there is nothing to
        // insert into. That is not a failure: the result stays in the app and
        // the user copies it, exactly as it worked before this phase.
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            capturedElement = nil
            return nil
        }

        let target = InsertionTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )

        // Only readable when trust has been granted. Its absence is not fatal:
        // the element is re-read at insertion time anyway, and this copy exists
        // to notice that the focus moved *within* the same application.
        capturedElement = focusedElement(of: target).map { (target.id, $0) }

        Log.insertion.debug("Target captured: \(target.logIdentity, privacy: .public)")
        return target
    }

    // MARK: - Insertion

    func insert(_ text: String, into target: InsertionTarget?) async -> InsertionOutcome {
        let element = target.flatMap(focusedElement(of:))
        let context = makeContext(target: target, focused: element)
        defer { capturedElement = nil }
        let plan = InsertionPolicy.plan(for: context)

        switch plan {
        case .write:
            guard let element else { return copyToClipboard(text, reason: .noEditableField) }
            if write(text, into: element) {
                return finish(.inserted(.focusedElement), target: target)
            }
            // The element said it was settable and then refused. Pasting is the
            // next method rather than the clipboard, because the field is real
            // and focused — only this route into it did not work.
            Log.insertion.debug("Direct write refused by the element; falling back to paste")
            return await paste(text, into: target)

        case .paste:
            return await paste(text, into: target)

        case let .clipboard(reason):
            return copyToClipboard(text, reason: reason)

        case let .refuse(reason):
            // The one outcome that leaves the pasteboard untouched.
            Log.insertion.info("Insertion refused: \(reason.rawValue, privacy: .public)")
            return .refused(reason)
        }
    }

    // MARK: - Context

    private func makeContext(target: InsertionTarget?, focused: AXUIElement?) -> InsertionContext {
        var context = InsertionContext(
            isTrusted: permissionService.currentAuthorization.allowsInsertion,
            hasTarget: target != nil,
            targetIsCurrent: target.map(isCurrent) ?? false,
            focusIsCurrent: focusIsUnchanged(target: target, focused: focused),
            secureInputEnabled: IsSecureEventInputEnabled(),
            focusedFieldIsSecure: false,
            hasEditableField: false,
            acceptsDirectWrite: false
        )

        guard let focused else { return context }

        let subrole = string(of: focused, attribute: kAXSubroleAttribute)
        context.focusedFieldIsSecure = subrole == (kAXSecureTextFieldSubrole as String)

        let role = string(of: focused, attribute: kAXRoleAttribute)
        let selectedTextIsSettable = isSettable(focused, attribute: kAXSelectedTextAttribute)
        let valueIsSettable = isSettable(focused, attribute: kAXValueAttribute)

        context.hasEditableField = Self.textRoles.contains(role ?? "") || selectedTextIsSettable || valueIsSettable
        context.acceptsDirectWrite = selectedTextIsSettable
        return context
    }

    /// Roles that are a text field even when the application exposes nothing as
    /// settable. Chromium and Electron are the reason this list exists.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Whether focus is still where it was when recording started.
    ///
    /// Unknowable without trust, and unknowable when either side has no
    /// element — an application that vends no focused element cannot have moved
    /// one. Both of those answer "unchanged", because a fallback the user
    /// cannot explain is worse than the narrow case this is here to catch.
    private func focusIsUnchanged(target: InsertionTarget?, focused: AXUIElement?) -> Bool {
        guard let target, let focused else { return true }
        guard let captured = capturedElement, captured.targetID == target.id else { return true }
        return CFEqual(captured.element, focused)
    }

    private func isCurrent(_ target: InsertionTarget) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == target.processIdentifier && !frontmost.isTerminated
    }

    // MARK: - Methods

    private func write(_ text: String, into element: AXUIElement) -> Bool {
        let prefix = InsertionSpacing.prefix(forCharacterBefore: characterBeforeCaret(in: element), text: text)
        let payload = prefix + text
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, payload as CFTypeRef)
        return status == .success
    }

    private func paste(_ text: String, into target: InsertionTarget?) async -> InsertionOutcome {
        guard let target, isCurrent(target) else { return copyToClipboard(text, reason: .targetChanged) }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return copyToClipboard(text, reason: .insertionFailed)
        }

        let prefix = focusedElement(of: target)
            .flatMap(characterBeforeCaret(in:))
            .map { InsertionSpacing.prefix(forCharacterBefore: $0, text: text) } ?? ""

        let snapshot = pasteboard.snapshot()
        let ourChangeCount = pasteboard.write(prefix + text)

        guard postCommandV(source: source) else {
            // Nothing was pasted, so the text stays on the pasteboard for the
            // user instead of being restored away from them.
            return .copiedToClipboard(.insertionFailed)
        }

        try? await Task.sleep(for: Self.pasteSettlingDelay)
        pasteboard.restore(snapshot, ifChangeCountIs: ourChangeCount)
        return finish(.inserted(.syntheticPaste), target: target)
    }

    private func postCommandV(source: CGEventSource) -> Bool {
        let key = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func copyToClipboard(_ text: String, reason: ClipboardReason) -> InsertionOutcome {
        pasteboard.write(text)
        Log.insertion.info("Text left on the clipboard: \(reason.rawValue, privacy: .public)")
        return .copiedToClipboard(reason)
    }

    private func finish(_ outcome: InsertionOutcome, target: InsertionTarget?) -> InsertionOutcome {
        Log.insertion.info(
            "\(outcome.logLabel, privacy: .public) into \(target?.logIdentity ?? "none", privacy: .public)"
        )
        return outcome
    }

    // MARK: - Accessibility plumbing

    private func focusedElement(of target: InsertionTarget) -> AXUIElement? {
        guard permissionService.currentAuthorization.allowsInsertion else { return nil }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let value = copyAttribute(application, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    /// The single character the spacing rule is allowed to look at.
    ///
    /// Read, used, and dropped inside this call. It is never stored, never
    /// logged, and never travels further than the `String` returned to the
    /// caller of `prefix(forCharacterBefore:text:)`.
    private func characterBeforeCaret(in element: AXUIElement) -> Character? {
        guard let rangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        guard range.location > 0 else { return nil }

        guard let value = copyAttribute(element, kAXValueAttribute) as? String else { return nil }
        let text = value as NSString
        guard range.location <= text.length else { return nil }
        let scalarRange = NSRange(location: range.location - 1, length: 1)
        guard scalarRange.location >= 0, NSMaxRange(scalarRange) <= text.length else { return nil }
        return text.substring(with: scalarRange).first
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value
    }

    private func string(of element: AXUIElement, attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }
}
