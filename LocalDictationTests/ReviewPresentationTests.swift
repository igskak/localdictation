import XCTest
@testable import Witness

/// Overlap resolution is the part a view cannot be trusted to get right, so it
/// is computed here and tested without SwiftUI.
final class ReviewPresentationTests: XCTestCase {
    private func span(
        _ range: Range<Int>,
        weight: Double,
        reason: RiskReason = .number,
        text: String
    ) -> RiskSpan {
        RiskSpan(
            reason: reason,
            rawRange: range,
            cleanedRange: range,
            weight: weight,
            text: text,
            start: 0,
            end: 0.5
        )
    }

    func testTextIsSplitIntoMarkedAndUnmarkedRuns() {
        let text = "Bitte 1450 Euro"
        let presentation = ReviewPresentation(
            text: text,
            highlighted: [span(6..<10, weight: 0.8, text: "1450")],
            flagged: [span(6..<10, weight: 0.8, text: "1450")]
        )

        XCTAssertEqual(presentation.segments.map(\.text), ["Bitte ", "1450", " Euro"])
        XCTAssertEqual(presentation.segments.map(\.isMarked), [false, true, false])
        XCTAssertEqual(presentation.segments.map(\.text).joined(), text)
    }

    func testEveryCharacterSurvivesTheSplit() {
        let text = "Переведи 1450 евро Мюллеру"
        let presentation = ReviewPresentation(
            text: text,
            highlighted: [
                span(9..<13, weight: 0.8, text: "1450"),
                span(14..<18, weight: 0.8, reason: .currency, text: "евро"),
                span(19..<26, weight: 0.6, reason: .namedEntity, text: "Мюллеру"),
            ],
            flagged: [
                span(9..<13, weight: 0.8, text: "1450"),
                span(14..<18, weight: 0.8, reason: .currency, text: "евро"),
                span(19..<26, weight: 0.6, reason: .namedEntity, text: "Мюллеру"),
            ]
        )

        XCTAssertEqual(presentation.segments.map(\.text).joined(), text)
        XCTAssertEqual(presentation.segments.filter(\.isMarked).map(\.text), ["1450", "евро", "Мюллеру"])
    }

    /// Two marks on the same characters must not split a word into fragments
    /// the user cannot read; the heavier one wins the whole overlap.
    func testOverlappingMarksResolveToTheHeavierOne() {
        let text = "Betrag 1450 Euro"
        let presentation = ReviewPresentation(
            text: text,
            highlighted: [
                span(7..<11, weight: 0.4, reason: .cleanupEdit(.capitalization), text: "1450"),
                span(7..<11, weight: 0.9, reason: .number, text: "1450"),
            ],
            flagged: [
                span(7..<11, weight: 0.4, reason: .cleanupEdit(.capitalization), text: "1450"),
                span(7..<11, weight: 0.9, reason: .number, text: "1450"),
            ]
        )

        let marked = presentation.segments.filter(\.isMarked)
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.span?.reason, .number)
    }

    func testAMarkWithNoExtentIsExplainedRatherThanHighlighted() {
        let removal = RiskSpan(
            reason: .cleanupEdit(.fillerRemoval),
            rawRange: 0..<4,
            cleanedRange: 0..<0,
            weight: 0.6,
            text: "",
            start: 0,
            end: 0.2
        )
        let presentation = ReviewPresentation(text: "Der Termin steht.", highlighted: [removal], flagged: [removal])

        XCTAssertTrue(presentation.hasPositionOnlyMarks)
        XCTAssertTrue(presentation.segments.allSatisfy { !$0.isMarked })
        XCTAssertEqual(presentation.explanations.first?.fragment, "removed here")
    }

    func testEveryFlaggedSpanIsExplained() {
        let presentation = ReviewPresentation(
            text: "Bitte 1450 Euro",
            highlighted: [
                span(6..<10, weight: 0.8, text: "1450"),
                span(11..<15, weight: 0.8, reason: .currency, text: "Euro"),
            ],
            flagged: [
                span(6..<10, weight: 0.8, text: "1450"),
                span(11..<15, weight: 0.8, reason: .currency, text: "Euro"),
            ]
        )

        XCTAssertEqual(presentation.explanations.count, 2)
        XCTAssertEqual(presentation.explanations.map(\.label), ["Number", "Amount"])
        XCTAssertTrue(presentation.explanations.allSatisfy(\.isPlayable))
        XCTAssertEqual(presentation.summary, "2 fragments worth checking")
    }

    func testUnflaggedTextProducesOneUnmarkedSegment() {
        let presentation = ReviewPresentation(text: "Der Termin steht.", highlighted: [], flagged: [])

        XCTAssertEqual(presentation.segments.count, 1)
        XCTAssertFalse(presentation.segments[0].isMarked)
        XCTAssertEqual(presentation.summary, "Nothing flagged")
    }

    func testOutOfBoundsSpansAreIgnoredRatherThanTrapping() {
        let presentation = ReviewPresentation(
            text: "Kurz",
            highlighted: [span(100..<140, weight: 0.9, text: "nonsense")],
            flagged: [span(100..<140, weight: 0.9, text: "nonsense")]
        )

        XCTAssertEqual(presentation.segments.map(\.text).joined(), "Kurz")
    }
}
