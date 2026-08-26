import Foundation

/// How the text reached the target application.
enum InsertionMethod: String, Sendable, Equatable, CaseIterable {
    /// Written straight into the focused element through Accessibility. No
    /// clipboard, no synthetic keys, and the target's own undo usually reverses
    /// it in one step.
    case focusedElement
    /// Written to the pasteboard and pasted with a synthetic ⌘V, with the
    /// previous pasteboard contents restored afterwards.
    case syntheticPaste

    var label: String {
        switch self {
        case .focusedElement: "direct"
        case .syntheticPaste: "paste"
        }
    }
}

/// Why the text ended up on the clipboard instead of in the target.
///
/// Each case is a normal outcome with its own sentence, not an error code.
/// `docs/PHASE_4.md` is explicit that direct insertion is preferred and never
/// promised, and this is what makes that honest.
enum ClipboardReason: String, Sendable, Equatable, CaseIterable {
    case notTrusted
    case noTarget
    case targetChanged
    case insertionFailed

    var message: String {
        switch self {
        case .notTrusted:
            "Copied to the clipboard. Grant Accessibility access to have it typed for you."
        case .noTarget:
            "Copied to the clipboard — there was no other application to put it in."
        case .targetChanged:
            "Copied to the clipboard: you moved to a different application while this was being prepared."
        case .insertionFailed:
            "Copied to the clipboard: that application would not accept the text directly."
        }
    }
}

/// Why nothing happened at all.
///
/// A refusal is the one outcome that leaves the clipboard alone. A password
/// field means a login screen or a password manager, and quietly leaving spoken
/// text on the system clipboard there is a leak in exchange for nothing.
enum RefusalReason: String, Sendable, Equatable, CaseIterable {
    case secureField
    case secureInput

    /// The sentence the user reads.
    ///
    /// Secure input takes a holder because the bare fact is unusable. It is a
    /// single process-wide flag, so while it is on *every* dictation everywhere
    /// is refused — `docs/PHASE_4_COMPATIBILITY.md` calls that the worst
    /// failure mode in the insertion path, because it looks like this app is
    /// broken rather than careful. "An application has secure input enabled",
    /// said to someone with thirty applications open, is a description of a
    /// problem with no action attached to it. A name is the action.
    func message(holder: String? = nil) -> String {
        switch self {
        case .secureField:
            return "Nothing was inserted: the focus is in a password field. The text is here and was not copied."
        case .secureInput:
            guard let holder else {
                return """
                Nothing was inserted: an application has secure input enabled, which blocks dictation \
                everywhere until it stops. The text is here and was not copied.
                """
            }
            return """
            Nothing was inserted: \(holder) has secure input enabled, which blocks dictation everywhere \
            until it stops. Switching to it and clicking into an ordinary field usually clears it; \
            quitting it always does. The text is here and was not copied.
            """
        }
    }
}

enum InsertionOutcome: Sendable, Equatable {
    case inserted(InsertionMethod)
    case copiedToClipboard(ClipboardReason)
    /// A refusal, and the application responsible where the system names one.
    /// Only secure input has a holder; a password field is the one the user is
    /// already looking at.
    case refused(RefusalReason, holder: String? = nil)

    var didInsert: Bool {
        if case .inserted = self { return true }
        return false
    }

    /// Whether the text is now on the clipboard. False for a refusal, which is
    /// exactly the point of the refusal.
    var isOnClipboard: Bool {
        if case .copiedToClipboard = self { return true }
        return false
    }

    /// The sentence the user reads. An insertion says nothing: the text
    /// appearing where they were typing is the message.
    var message: String? {
        switch self {
        case .inserted: nil
        case let .copiedToClipboard(reason): reason.message
        case let .refused(reason, holder): reason.message(holder: holder)
        }
    }

    /// Non-content summary for logs and developer diagnostics.
    var logLabel: String {
        switch self {
        case let .inserted(method): "inserted:\(method.rawValue)"
        case let .copiedToClipboard(reason): "clipboard:\(reason.rawValue)"
        case let .refused(reason, _): "refused:\(reason.rawValue)"
        }
    }
}
