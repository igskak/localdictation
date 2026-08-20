import Foundation

/// The review strip's content, computed without SwiftUI.
///
/// Overlap resolution is the part worth testing: two signals can mark the same
/// characters, and a naive renderer would either draw one mark on top of the
/// other or split a word into fragments the user cannot read. Doing it here
/// keeps the view a straight translation of a value.
struct ReviewPresentation: Sendable, Equatable {
    /// A run of cleaned text that either carries one mark or carries none.
    struct Segment: Sendable, Equatable, Identifiable {
        let id: Int
        let text: String
        let span: RiskSpan?
        /// Whether this mark is one of the ones that lit the indicator, as
        /// opposed to one shown only because the user is already looking. The
        /// two are drawn differently on purpose: a review where every mark
        /// shouts equally is a review with no shape, and the user has to read
        /// all of it to find the part that mattered.
        let isFlagged: Bool

        var isMarked: Bool { span != nil }
    }

    /// One line in the list under the text, explaining a mark.
    struct Explanation: Sendable, Equatable, Identifiable {
        let id: Int
        let span: RiskSpan
        let label: String
        /// The marked fragment, or a description of what was removed when the
        /// mark has no extent in the cleaned text.
        let fragment: String
        let isPlayable: Bool
        let isFlagged: Bool
    }

    let segments: [Segment]
    let explanations: [Explanation]
    /// How many marks earned the indicator. This is the number the chip showed,
    /// so it has to be the number the review shows too — a chip that says two
    /// and a panel that says five reads as the app changing its mind.
    let flaggedCount: Int
    /// How many further marks are shown only because the review is open.
    let secondaryCount: Int
    /// Marks that are worth explaining but have nothing to highlight — a
    /// removed filler occupies a position in the cleaned text, not an extent.
    let hasPositionOnlyMarks: Bool

    /// `highlighted` is everything the review draws and `flagged` is the subset
    /// that caused it to be offered. `flagged` must be a subset of
    /// `highlighted`; `ReviewPolicy` guarantees it by construction.
    init(text: String, highlighted: [RiskSpan], flagged: [RiskSpan]) {
        let characters = Array(text)
        let length = characters.count

        // Higher weight wins the characters it shares with a lighter mark, so
        // "amount" beats "punctuation" on the same word rather than the two
        // splitting it between them.
        var owners = [Int?](repeating: nil, count: length)
        let ordered = highlighted.enumerated().sorted { $0.element.weight < $1.element.weight }
        for (index, span) in ordered {
            let range = span.cleanedRange
            guard range.lowerBound >= 0, range.upperBound <= length else { continue }
            for position in range { owners[position] = index }
        }

        var segments: [Segment] = []
        var position = 0
        var segmentID = 0
        while position < length {
            let owner = owners[position]
            var end = position
            while end < length, owners[end] == owner { end += 1 }
            let span = owner.map { highlighted[$0] }
            segments.append(
                Segment(
                    id: segmentID,
                    text: String(characters[position..<end]),
                    span: span,
                    isFlagged: span.map { flagged.contains($0) } ?? false
                )
            )
            segmentID += 1
            position = end
        }
        if segments.isEmpty, !text.isEmpty {
            segments = [Segment(id: 0, text: text, span: nil, isFlagged: false)]
        }

        self.segments = segments
        self.flaggedCount = flagged.count
        self.secondaryCount = max(highlighted.count - flagged.count, 0)
        self.hasPositionOnlyMarks = highlighted.contains { !$0.hasExtentInCleanedText }
        // Flagged marks first: the user came here for those, and reading past
        // three punctuation notes to reach the amount is the review failing at
        // the one job it has.
        let ordering = highlighted.enumerated().sorted { left, right in
            let leftFlagged = flagged.contains(left.element)
            let rightFlagged = flagged.contains(right.element)
            if leftFlagged != rightFlagged { return leftFlagged }
            return left.offset < right.offset
        }
        self.explanations = ordering.enumerated().map { index, entry in
            Explanation(
                id: index,
                span: entry.element,
                label: entry.element.reason.label,
                fragment: Self.fragment(for: entry.element),
                isPlayable: entry.element.isPlayable,
                isFlagged: flagged.contains(entry.element)
            )
        }
    }

    private static func fragment(for span: RiskSpan) -> String {
        guard span.text.isEmpty else { return span.text }
        if case let .cleanupEdit(kind) = span.reason, kind == .fillerRemoval {
            return "removed here"
        }
        return "at this position"
    }

    /// The headline above the strip. It says how many fragments are worth
    /// checking, because "review" on its own does not tell the user whether
    /// this will take one second or ten.
    var summary: String {
        switch flaggedCount {
        case 0: "Nothing flagged"
        case 1: "1 fragment worth checking"
        default: "\(flaggedCount) fragments worth checking"
        }
    }

    /// Names the lighter marks, so the user can tell at a glance that the extra
    /// underlines are not five more things they were supposed to worry about.
    var secondarySummary: String? {
        guard secondaryCount > 0 else { return nil }
        return secondaryCount == 1 ? "1 more marked for context" : "\(secondaryCount) more marked for context"
    }
}
