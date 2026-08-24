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
/// Everything here runs on the main actor and synchronously, apart from two
/// genuine waits: the pasteboard the target has to read before the previous
/// contents go back, and the moment a written field is given to prove it kept
/// the text. Accessibility calls to a responsive application return in well
/// under a millisecond; the messaging timeout bounds the case where the target
/// has hung, which is a state the user's Mac is already visibly in.
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

    /// How long a written field is given before it is measured a second time.
    /// Long enough for a web editor to put its own value back on the next turn
    /// of its event loop, short enough to disappear inside the click that
    /// started the insertion.
    private static let writeSettlingDelay = Duration.milliseconds(40)

    /// How often the frontmost application is re-read while waiting, and how
    /// many times. Fifteen reads at 40 ms is a 600 ms grace: longer than the
    /// system panels that steal the front and shorter than a user noticing a
    /// delay before their text arrives.
    private static let frontmostPollInterval = Duration.milliseconds(40)
    private static let frontmostPollAttempts = 15

    /// How long a readable field is watched for the pasted text to appear.
    /// Fifteen reads at 40 ms again, which is well past the point where an
    /// application under load has read the pasteboard.
    private static let pasteVerificationAttempts = 15

    /// How long the user's fingers are given to come off the modifier keys
    /// before a synthetic ⌘V is posted anyway.
    private static let modifierPollInterval = Duration.milliseconds(20)
    private static let modifierPollAttempts = 5

    /// The Electron opt-in. Chromium builds no accessibility tree until an
    /// assistive technology asks for one, and Electron exposes that request as
    /// a settable attribute on the application element. Held as a `String`
    /// because the ask runs off the main actor, and a `CFString` cannot cross
    /// that boundary.
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

    private let permissionService: any AccessibilityPermissionService
    private let pasteboard: any Pasteboard
    private let frontmost: any FrontmostApplicationSource

    /// Applications already asked to build their accessibility tree.
    ///
    /// Only to keep the app from asking and logging on every hotkey press. A
    /// process identifier that has been reused since means one redundant ask
    /// that is skipped, which costs an application nothing it would not have
    /// paid anyway the first time.
    private var askedForAccessibilityTree: Set<pid_t> = []

    init(
        permissionService: any AccessibilityPermissionService = AXAccessibilityPermissionService(),
        pasteboard: any Pasteboard = SystemPasteboard(),
        frontmost: any FrontmostApplicationSource = SystemFrontmostApplications()
    ) {
        self.permissionService = permissionService
        self.pasteboard = pasteboard
        self.frontmost = frontmost
    }

    // MARK: - Capture

    func captureTarget() -> InsertionTarget? {
        guard let application = frontmost.frontmostApplication else { return nil }
        // Dictating with our own window in front means there is nothing to
        // insert into. That is not a failure: the result stays in the app and
        // the user copies it, exactly as it worked before this phase.
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let target = InsertionTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )

        askForAccessibilityTree(of: target)

        Log.insertion.debug("Target captured: \(target.logIdentity, privacy: .public)")
        return target
    }

    /// Asks an Electron application to build its accessibility tree.
    ///
    /// Chromium does not build one until an assistive technology asks, so a
    /// focused, perfectly ordinary message box comes back as nothing focused at
    /// all — which is what Flock did, and what left the text on the clipboard
    /// with a sentence about focus the user could do nothing with. Electron
    /// takes `AXManualAccessibility` as that request; every other application
    /// ignores the attribute, which is why this is set without asking what the
    /// target is.
    ///
    /// It is asked at the hotkey rather than at insertion because the tree is
    /// built asynchronously. Recording, transcription, and cleanup are seconds
    /// the application can spend building it, and by the time there is text to
    /// insert the element is there to insert into.
    ///
    /// It is asked *off* the main actor because the ask is a synchronous call
    /// into another process, and an application that does not answer costs the
    /// whole messaging timeout. That was measured on this Mac: the hotkey went
    /// down at 17:20:05.746 and the microphone opened at 17:20:06.325, because
    /// Xcode took the full half second to answer — and the user's first word
    /// went into the half second the app spent waiting. Nothing here needs the
    /// answer, so nothing waits for it.
    private func askForAccessibilityTree(of target: InsertionTarget) {
        guard permissionService.currentAuthorization.allowsInsertion else { return }
        guard !askedForAccessibilityTree.contains(target.processIdentifier) else { return }
        askedForAccessibilityTree.insert(target.processIdentifier)

        let processIdentifier = target.processIdentifier
        let identity = target.logIdentity
        let timeout = Self.messagingTimeout
        let attribute = Self.manualAccessibilityAttribute
        Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(application, timeout)
            let status = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
            guard status == .success else { return }
            Log.insertion.debug("Asked \(identity, privacy: .public) for its accessibility tree")
        }
    }

    // MARK: - Insertion

    func insert(_ text: String, into target: InsertionTarget?) async -> InsertionOutcome {
        // Only worth waiting for when the wait can change the answer. Without
        // trust the text goes to the clipboard whoever is in front.
        if let target, permissionService.currentAuthorization.allowsInsertion {
            _ = await waitForTargetToComeBack(target)
        }
        let element = target.flatMap(focusedElement(of:))
        let context = makeContext(target: target, focused: element)
        let plan = InsertionPolicy.plan(for: context)

        switch plan {
        case .write:
            guard let element else { return await paste(text, into: target) }
            if await write(text, into: element) {
                return finish(.inserted(.focusedElement), target: target)
            }
            // The element said it was settable and then refused, or took the
            // write and did nothing with it. Pasting is the next method rather
            // than the clipboard, because the field is real and focused — only
            // this route into it did not work.
            Log.insertion.debug("Direct write did not land; falling back to paste")
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
            targetIsCurrent: target.map { isCurrent($0) } ?? false,
            secureInputEnabled: IsSecureEventInputEnabled(),
            focusedFieldIsSecure: false,
            acceptsDirectWrite: false
        )

        guard let focused else { return context }

        let subrole = string(of: focused, attribute: kAXSubroleAttribute)
        context.focusedFieldIsSecure = subrole == (kAXSecureTextFieldSubrole as String)

        // The only thing left to ask the element: whether it can be written
        // through Accessibility. Everything it cannot answer for itself is
        // handled by pasting into it.
        context.acceptsDirectWrite = isSettable(focused, attribute: kAXSelectedTextAttribute)
        return context
    }

    /// Whether the application spoken into is still the one in front.
    ///
    /// The failure is logged with the identity of whatever is in front instead,
    /// because "you moved to a different application" is a sentence the user
    /// can only act on if it is true, and the only way to find out that it was
    /// not is to know which application the check actually saw. Both halves are
    /// bundle identifiers and process identifiers: application identity, never
    /// anything read out of a window.
    private func isCurrent(_ target: InsertionTarget, logFailure: Bool = true) -> Bool {
        guard let application = frontmost.frontmostApplication else {
            if logFailure {
                Log.insertion.debug("Nothing is frontmost; target \(target.logIdentity, privacy: .public) treated as gone")
            }
            return false
        }
        guard application.processIdentifier == target.processIdentifier, !application.isTerminated else {
            if logFailure {
                Log.insertion.debug(
                    """
                    Target \(target.logIdentity, privacy: .public) is not frontmost; \
                    in front is \(application.logIdentity, privacy: .public)
                    """
                )
            }
            return false
        }
        return true
    }

    /// Gives a target that is not in front a moment to come back, and says
    /// whether it did.
    ///
    /// System windows take the front without the user going anywhere. The log
    /// on this Mac has `com.apple.loginwindow` in front of a messenger twice
    /// inside six seconds while its owner did nothing but type, and a Wi-Fi
    /// prompt, a Touch ID sheet, or a screen-lock panel does the same. Reading
    /// the frontmost application once, at the instant the text happens to be
    /// ready, turns any of those into "you moved to a different application" —
    /// a sentence that is both wrong and impossible to act on.
    ///
    /// Waiting is safe in the way that guessing is not. The text still only
    /// ever goes to the application it was spoken into; the wait only decides
    /// how long that application is allowed to be behind a system panel. It
    /// costs nothing in the normal case, where the first read succeeds.
    @discardableResult
    func waitForTargetToComeBack(_ target: InsertionTarget) async -> Bool {
        if isCurrent(target, logFailure: false) { return true }

        for attempt in 1...Self.frontmostPollAttempts {
            try? await Task.sleep(for: Self.frontmostPollInterval)
            guard isCurrent(target, logFailure: false) else { continue }
            Log.insertion.debug(
                """
                Target \(target.logIdentity, privacy: .public) came back to the front \
                after \(attempt, privacy: .public) polls
                """
            )
            return true
        }
        return false
    }

    // MARK: - Methods

    /// Writes into the focused element, and returns whether the text is
    /// actually in it.
    ///
    /// The second half is the point. `AXUIElementSetAttributeValue` returning
    /// `success` means the element accepted the message, not that it did
    /// anything with it: Safari's web fields and parts of Electron accept a
    /// write to `AXSelectedText` and ignore it. That was reported to the user
    /// as a successful insertion — which shows no notice, by design — so the
    /// text went nowhere and the app said nothing about it.
    ///
    /// So the field is measured before and after, and a write it ignored is
    /// treated exactly like one it refused: the paste path takes over.
    ///
    /// It is measured twice, because a web page has two ways to swallow a
    /// write. It can ignore the call outright, which the first check catches,
    /// and it can let the value through and then put its own back on the next
    /// turn of its event loop — an editor that keeps the field's contents in
    /// its own state does exactly that. The second check catches a field that
    /// has gone back to precisely what it was, which is the one shape in which
    /// pasting cannot insert the text twice.
    private func write(_ text: String, into element: AXUIElement) async -> Bool {
        let prefix = InsertionSpacing.prefix(forCharacterBefore: characterBeforeCaret(in: element), text: text)
        let payload = prefix + text
        let before = fingerprint(of: element)
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, payload as CFTypeRef)
        guard status == .success else { return false }

        guard InsertionVerification.didApply(before: before, after: fingerprint(of: element)) else {
            Log.insertion.debug("The element accepted the write and did not change")
            return false
        }

        try? await Task.sleep(for: Self.writeSettlingDelay)
        guard InsertionVerification.didApply(before: before, after: fingerprint(of: element)) else {
            Log.insertion.debug("The field went back to what it was after the write")
            return false
        }
        return true
    }

    /// How much text the element holds and where its insertion point is.
    ///
    /// Both numbers are read, compared, and dropped inside `write(_:into:)`.
    /// Neither is stored and neither is logged: a length and a caret position
    /// are facts about the shape of a field, not about what the user wrote in
    /// it. The character count is preferred over the value because it is a
    /// number rather than the document, and reading the value is the fallback
    /// only for elements that do not vend the count.
    private func fingerprint(of element: AXUIElement) -> TextFieldFingerprint {
        var fingerprint = TextFieldFingerprint()

        if let count = copyAttribute(element, kAXNumberOfCharactersAttribute) as? Int {
            fingerprint.characterCount = count
        } else if let value = copyAttribute(element, kAXValueAttribute) as? String {
            fingerprint.characterCount = (value as NSString).length
        }

        if let range = selectedRange(of: element) {
            fingerprint.selectionLocation = range.location
            fingerprint.selectionLength = range.length
        }

        return fingerprint
    }

    private func paste(_ text: String, into target: InsertionTarget?) async -> InsertionOutcome {
        guard let target, isCurrent(target) else { return copyToClipboard(text, reason: .targetChanged) }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return copyToClipboard(text, reason: .insertionFailed)
        }

        let element = focusedElement(of: target)
        let prefix = element
            .flatMap(characterBeforeCaret(in:))
            .map { InsertionSpacing.prefix(forCharacterBefore: $0, text: text) } ?? ""
        let before = element.map(fingerprint(of:))

        let snapshot = pasteboard.snapshot()
        let ourChangeCount = pasteboard.write(prefix + text)

        await waitForModifiersToClear()

        guard postCommandV(source: source) else {
            // Nothing was pasted, so the text stays on the pasteboard for the
            // user instead of being restored away from them.
            return .copiedToClipboard(.insertionFailed)
        }

        guard await pasteLanded(in: element, before: before) else {
            // The field is readable and says it is unchanged: the ⌘V went
            // somewhere that did nothing with it. The text is deliberately
            // left on the pasteboard rather than restored away from the user,
            // and the outcome says so instead of reporting an insertion the
            // way a swallowed direct write once did.
            Log.insertion.debug("The paste did not reach the field")
            return .copiedToClipboard(.insertionFailed)
        }

        pasteboard.restore(snapshot, ifChangeCountIs: ourChangeCount)
        return finish(.inserted(.syntheticPaste), target: target)
    }

    /// Waits for the pasted text to appear, and says whether it did.
    ///
    /// This replaces a flat 200 ms sleep, which was a bet that every
    /// application reads the pasteboard within 200 ms of the ⌘V. One that is
    /// busy, or that is talking to a virtual machine or a remote desktop, reads
    /// it later — and by then the previous pasteboard contents are back and the
    /// user's dictation is gone with no notice, because the app had already
    /// called it an insertion.
    ///
    /// So a field that describes itself is watched instead: any change to its
    /// length or its caret means the paste arrived, and the pasteboard goes
    /// back the moment it does — sooner than 200 ms in the common case. A field
    /// that describes nothing cannot be watched, so it gets the settling delay
    /// and the benefit of the doubt, exactly as an unverifiable direct write
    /// does.
    private func pasteLanded(in element: AXUIElement?, before: TextFieldFingerprint?) async -> Bool {
        guard let element, let before, before.isReadable else {
            try? await Task.sleep(for: Self.pasteSettlingDelay)
            return true
        }

        for _ in 1...Self.pasteVerificationAttempts {
            try? await Task.sleep(for: Self.frontmostPollInterval)
            if InsertionVerification.didApply(before: before, after: fingerprint(of: element)) { return true }
        }
        return false
    }

    /// Waits for the user's fingers to come off the modifier keys.
    ///
    /// A synthetic ⌘V arrives at the target carrying whatever is physically
    /// held down with it. With Shift still down that is ⇧⌘V, which is "paste
    /// and match style" in one application, "paste as plain text" in another,
    /// and a Markdown preview in a third; with Option it is a different
    /// command again. Insertion normally happens a second or more after the
    /// hotkey is released, so this wait usually returns on its first look.
    private func waitForModifiersToClear() async {
        for _ in 1...Self.modifierPollAttempts {
            guard !heldModifiers.isEmpty else { return }
            try? await Task.sleep(for: Self.modifierPollInterval)
        }
        Log.insertion.debug("Modifier keys are still down; pasting anyway")
    }

    /// The modifiers that change what ⌘V means. Caps lock is not one of them.
    private var heldModifiers: CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
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
        guard let range = selectedRange(of: element) else { return nil }
        guard range.location > 0 else { return nil }

        guard let value = copyAttribute(element, kAXValueAttribute) as? String else { return nil }
        let text = value as NSString
        guard range.location <= text.length else { return nil }
        let scalarRange = NSRange(location: range.location - 1, length: 1)
        guard scalarRange.location >= 0, NSMaxRange(scalarRange) <= text.length else { return nil }
        return text.substring(with: scalarRange).first
    }

    /// The selection, as the element reports it: an insertion point is a range
    /// of length zero. A position and a length, never any text.
    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let rangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
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

/// The real frontmost application, read from `NSWorkspace`.
@MainActor
final class SystemFrontmostApplications: FrontmostApplicationSource {
    var frontmostApplication: FrontmostApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            isTerminated: application.isTerminated
        )
    }
}
