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
