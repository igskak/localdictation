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
    /// Some application has secure input enabled, process-wide.
    var secureInputEnabled: Bool
    /// The name of the application holding secure input, when the window
    /// server names one. Carried through the decision rather than read at the
    /// end, so the sentence the user gets is about the state the refusal was
    /// actually taken on.
    var secureInputHolderName: String?
    /// The focused element is a password field.
    var focusedFieldIsSecure: Bool
    /// The focused element's selected text is settable, so it can be written
    /// through Accessibility rather than pasted into.
    var acceptsDirectWrite: Bool
    /// macOS will let the app post a synthetic ⌘V. Distinct from `isTrusted`,
    /// which the app can hold while this is false — see `EventSynthesisSource`.
    var canSynthesizeEvents: Bool

    init(
        isTrusted: Bool = true,
        hasTarget: Bool = true,
        targetIsCurrent: Bool = true,
        secureInputEnabled: Bool = false,
        secureInputHolderName: String? = nil,
        focusedFieldIsSecure: Bool = false,
        acceptsDirectWrite: Bool = true,
        canSynthesizeEvents: Bool = true
    ) {
        self.isTrusted = isTrusted
        self.hasTarget = hasTarget
        self.targetIsCurrent = targetIsCurrent
        self.secureInputEnabled = secureInputEnabled
        self.secureInputHolderName = secureInputHolderName
        self.focusedFieldIsSecure = focusedFieldIsSecure
        self.acceptsDirectWrite = acceptsDirectWrite
        self.canSynthesizeEvents = canSynthesizeEvents
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

        // Inside that application, the text goes wherever the caret is now.
        // The first version also required the *field* to be the one dictated
        // into, comparing the element focused at the hotkey against the one
        // focused at insertion. It cost more than it bought: an AXUIElement for
        // a web or Electron field is not stable across the seconds a
        // transcription and a review take, so the check fired on fields nobody
        // had left and sent the text to the clipboard with a sentence about
        // moving focus that the user had not done.

        // Accessibility decides only *how* the text goes in, never whether it
        // goes in at all. A field that can be written through it is written
        // to; everything else is pasted into, including an application that
        // describes no focused element whatsoever — Chromium builds no tree
        // until it is asked, and a message box nobody can see through
        // Accessibility still takes ⌘V like any other.
        //
        // Asking the application for permission was the wrong question, and
        // asking it twice — is this a text field, is anything focused — cost
        // the user two working applications before the question was dropped.
        // What guards the insertion is the frontmost application and the
        // secure checks above.
        if context.acceptsDirectWrite { return .write }

        // Pasting is the only method left, and it is a keystroke. Posting one
        // the window server will drop puts the dictation on the pasteboard
        // either way — the difference is the sentence that goes with it, and
        // whether it names something the user can act on.
        return context.canSynthesizeEvents ? .paste : .clipboard(.cannotSynthesizeEvents)
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
