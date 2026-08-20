import Foundation

/// What the app knows at the instant it is about to insert.
///
/// Gathered by the live service from the system; supplied directly by tests.
/// Splitting the facts from the mechanism is what makes the decision testable:
/// choosing between four paths is logic, and asking macOS whether a field is
/// secure is not.
struct InsertionContext: Sendable, Equatable {
    /// Accessibility trust. Without it neither insertion method can work.
    var isTrusted: Bool
    /// A target was captured when recording started.
    var hasTarget: Bool
    /// The captured target is still alive and still frontmost.
    var targetIsCurrent: Bool
    /// The element focused when recording started is still the focused one.
    ///
    /// Separate from `targetIsCurrent` because moving from the message box to
    /// the search field of the same application is also a wrong target, and
    /// the sentence the user reads about it is a different sentence.
    var focusIsCurrent: Bool
    /// Some application has secure input enabled, process-wide.
    var secureInputEnabled: Bool
    /// The focused element is a password field.
    var focusedFieldIsSecure: Bool
    /// There is a focused element that takes text at all.
    var hasEditableField: Bool
    /// The focused element's selected text is settable, so it can be written
    /// through Accessibility rather than pasted into.
    var acceptsDirectWrite: Bool

    init(
        isTrusted: Bool = true,
        hasTarget: Bool = true,
        targetIsCurrent: Bool = true,
        focusIsCurrent: Bool = true,
        secureInputEnabled: Bool = false,
        focusedFieldIsSecure: Bool = false,
        hasEditableField: Bool = true,
        acceptsDirectWrite: Bool = true
    ) {
        self.isTrusted = isTrusted
        self.hasTarget = hasTarget
        self.targetIsCurrent = targetIsCurrent
        self.focusIsCurrent = focusIsCurrent
        self.secureInputEnabled = secureInputEnabled
        self.focusedFieldIsSecure = focusedFieldIsSecure
        self.hasEditableField = hasEditableField
        self.acceptsDirectWrite = acceptsDirectWrite
    }
}

/// What the service is about to do.
enum InsertionPlan: Sendable, Equatable {
    case write
    case paste
    case clipboard(ClipboardReason)
    case refuse(RefusalReason)
}

/// Decides between writing, pasting, copying, and refusing.
///
/// A pure function of its inputs, and tested as one — the same shape as
/// `ReviewCoordinator.decide`. It performs no side effects and holds no state,
/// so the decision cannot depend on anything invisible to a test.
enum InsertionPolicy {
    static func plan(for context: InsertionContext) -> InsertionPlan {
        // Secure input first, and before the trust check on purpose. Secure
        // input is readable without Accessibility, and it is the one signal
        // that must suppress the clipboard as well as the insertion: text
        // spoken at a login screen belongs neither in the field nor in the
        // pasteboard.
        if context.secureInputEnabled { return .refuse(.secureInput) }
        if context.focusedFieldIsSecure { return .refuse(.secureField) }

        guard context.isTrusted else { return .clipboard(.notTrusted) }
        guard context.hasTarget else { return .clipboard(.noTarget) }

        // The target moved. The app does not guess: a wrong target is the worst
        // outcome available in this phase, because text meant for a document
        // lands in a message that sends on Return or a terminal that runs it.
        guard context.targetIsCurrent else { return .clipboard(.targetChanged) }
        guard context.focusIsCurrent else { return .clipboard(.focusChanged) }
        guard context.hasEditableField else { return .clipboard(.noEditableField) }

        return context.acceptsDirectWrite ? .write : .paste
    }
}

/// What a text element looks like from outside, in the two numbers that change
/// when text is inserted into it.
///
/// Non-content by construction: a count of characters and the position of the
/// insertion point say that the field changed, and nothing about what is in it.
/// Neither number is stored beyond the call that reads it, and neither is
/// logged.
///
/// Either half may be missing. An element that exposes no count and no
/// selection cannot be checked, and that is recorded as absence rather than
/// guessed at.
struct TextFieldFingerprint: Sendable, Equatable {
    var characterCount: Int?
    var selectionLocation: Int?
    var selectionLength: Int?

    init(characterCount: Int? = nil, selectionLocation: Int? = nil, selectionLength: Int? = nil) {
        self.characterCount = characterCount
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
    }

    /// Whether the element said anything at all about its text.
    var isReadable: Bool { characterCount != nil || selectionLocation != nil }
}

/// Decides whether a direct write actually put the text in the field.
///
/// It exists because `AXUIElementSetAttributeValue` returning `success` is not
/// the same as text appearing. Safari's web fields, and parts of Electron,
/// accept the call for `AXSelectedText` and do nothing with it. The app used to
/// believe them: it reported an insertion that had happened, showed no notice
/// because a successful insertion says nothing, and left the user looking at an
/// unchanged document.
///
/// So the element is asked what changed. Any change is enough — inserting a
/// non-empty string moves the count, the caret, or both, and which of them
/// moves depends on whether a selection was replaced. Only a field that reports
/// exactly what it reported before has ignored the write.
enum InsertionVerification {
    static func didApply(before: TextFieldFingerprint, after: TextFieldFingerprint) -> Bool {
        // Unverifiable, so the API's own answer stands. Falling back to a paste
        // here would risk inserting the text twice into an element that took it
        // and simply does not describe itself, which is worse than the silence
        // this check exists to end.
        guard before.isReadable, after.isReadable else { return true }
        return before != after
    }
}
