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
    }

    let segments: [Segment]
    let explanations: [Explanation]
    let flaggedCount: Int
    /// Marks that are worth explaining but have nothing to highlight — a
    /// removed filler occupies a position in the cleaned text, not an extent.
    let hasPositionOnlyMarks: Bool

    init(text: String, flagged: [RiskSpan]) {
        let characters = Array(text)
        let length = characters.count

        // Higher weight wins the characters it shares with a lighter mark, so
        // "amount" beats "punctuation" on the same word rather than the two
        // splitting it between them.
        var owners = [Int?](repeating: nil, count: length)
        let ordered = flagged.enumerated().sorted { $0.element.weight < $1.element.weight }
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
            segments.append(
                Segment(
                    id: segmentID,
                    text: String(characters[position..<end]),
                    span: owner.map { flagged[$0] }
                )
            )
            segmentID += 1
            position = end
        }
        if segments.isEmpty, !text.isEmpty {
            segments = [Segment(id: 0, text: text, span: nil)]
        }

        self.segments = segments
        self.flaggedCount = flagged.count
        self.hasPositionOnlyMarks = flagged.contains { !$0.hasExtentInCleanedText }
        self.explanations = flagged.enumerated().map { index, span in
            Explanation(
                id: index,
                span: span,
                label: span.reason.label,
                fragment: Self.fragment(for: span),
                isPlayable: span.isPlayable
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
        case 0: "Nothing to check"
        case 1: "1 fragment worth checking"
        default: "\(flaggedCount) fragments worth checking"
        }
    }
}
