import CoreGraphics
import Foundation

/// The boundary between the app's text and the rest of the system.
///
/// Every Accessibility call, synthetic key event, and pasteboard write in the
/// insertion path lives behind this protocol, so no test can reach the real
/// system and no test run can raise a permission prompt.
///
/// Main-actor bound, like `AudioFragmentPlayer`: this runs when a dictation
/// ends or a review is accepted, and has no real-time constraint. Async because
/// the paste path genuinely waits — the target application needs a moment to
/// read the pasteboard before the previous contents go back.
@MainActor
protocol TextInsertionService: AnyObject {
    /// The application in focus right now, captured so it can be inserted into
    /// later. Returns `nil` when there is nothing to insert into — LocalDictation
    /// itself in front, or no frontmost application at all.
    func captureTarget() -> InsertionTarget?

    /// Puts `text` into `target`, or explains why it did not.
    ///
    /// Never throws: every path ends in an `InsertionOutcome` the user can be
    /// told about, because "the text is on your clipboard" is a result and not
    /// a failure.
    func insert(_ text: String, into target: InsertionTarget?) async -> InsertionOutcome
}

/// An application as the insertion path needs to see it.
///
/// Identity and liveness, and nothing about its windows or their contents —
/// the same non-content rule as `InsertionTarget`, for the same reason.
struct FrontmostApplication: Sendable, Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    /// The name macOS shows for the application, carried because the user is
    /// told which application their text went into. Never logged.
    let localizedName: String?
    let isTerminated: Bool

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        isTerminated: Bool = false
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isTerminated = isTerminated
    }

    /// Identity for logs: a bundle identifier where there is one, and never a
    /// window title or a localized name.
    var logIdentity: String { bundleIdentifier ?? "pid:\(processIdentifier)" }
}

/// Which application is in front, behind a protocol.
///
/// It exists so that waiting for a target to come back to the front is a tested
/// behaviour rather than a hope. That wait is the difference between a message
/// box that takes the text and a sentence about switching applications the user
/// never switched, and it cannot be exercised at all if the only way to read
/// the frontmost application is to ask the real window server.
@MainActor
protocol FrontmostApplicationSource: AnyObject {
    /// The application in front at this instant, or `nil` when there is none.
    var frontmostApplication: FrontmostApplication? { get }
}

/// Whether macOS will let this app press a key on the user's behalf.
///
/// Separate from Accessibility trust because macOS treats it separately, and
/// the two come apart in a way that is invisible from inside the app.
/// `AXIsProcessTrusted()` is answered once for the life of the process, so an
/// app that was trusted when it launched goes on reading and writing focused
/// elements; permission to *synthesize* an event is checked by the window
/// server on every post, against the code signature the application has now. An
/// application replaced by a new build — every rebuild during development, and
/// every update the user installs — no longer matches the signature its grant
/// was recorded against, and the two answers diverge.
///
/// Nothing about that is visible from `CGEventPost`, which returns `Void`: the
/// key event is dropped, the window server logs `Sender is prohibited from
/// synthesizing events` where only `log show` will find it, and the app is left
/// to conclude from an unchanged field that the target application ignored the
/// paste. That conclusion was wrong, and it was the sentence the user got.
///
/// `CGPreflightPostEventAccess()` is the same question asked before the post,
/// where the answer can still be turned into something to do about it.
@MainActor
protocol EventSynthesisSource: AnyObject {
    var canSynthesizeEvents: Bool { get }
}

@MainActor
final class SystemEventSynthesis: EventSynthesisSource {
    /// Preflight only. The asking variant, `CGRequestPostEventAccess()`, would
    /// raise a system prompt from inside an insertion — in the middle of the
    /// second where the user is waiting for their sentence to appear, which is
    /// the worst moment available to interrupt them. The refusal names the
    /// setting instead, and the user goes there when it suits them.
    var canSynthesizeEvents: Bool { CGPreflightPostEventAccess() }
}

/// The one thing the app is allowed to invent about the surroundings.
///
/// Whether a leading space is needed depends on the character before the caret,
/// and reading that character is reading the user's document. So the rule is
/// exactly one rule and no more, per `docs/PHASE_4.md`: everything else that
/// lands in the target is the same string the Copy button would have produced.
enum InsertionSpacing {
    /// Opening brackets and quotes that a space must not follow.
    private static let openers: Set<Character> = ["(", "[", "{", "«", "„", "“", "\"", "'", "‘", "#", "@", "/", "-", "—"]

    static func prefix(forCharacterBefore character: Character?, text: String) -> String {
        // Nothing readable before the caret — an empty document, an element
        // that does not expose its contents, or a field we could not read.
        // Inventing a space here would put one at the start of an empty field.
        guard let character else { return "" }
        guard !character.isWhitespace, !character.isNewline else { return "" }
        guard !openers.contains(character) else { return "" }
        // The text itself already starts with a space or with punctuation that
        // attaches to the previous word.
        guard let first = text.first, !first.isWhitespace else { return "" }
        if first.isPunctuation, !openers.contains(first) { return "" }
        return " "
    }
}
