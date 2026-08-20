import XCTest
@testable import LocalDictation

/// The decision is a pure function of its inputs, and is tested as one.
final class ReviewCoordinatorTests: XCTestCase {
    private func span(weight: Double, reason: RiskReason = .number) -> RiskSpan {
        RiskSpan(
            reason: reason,
            rawRange: 0..<4,
            cleanedRange: 0..<4,
            weight: weight,
            text: "1450",
            start: 0,
            end: 0.5
        )
    }

    func testNothingMarkedMeansNothingIsSaid() {
        XCTAssertEqual(ReviewCoordinator.decide(spans: []), .quiet)
    }

    func testASpanAtTheAttentionThresholdEarnsTheIndicator() {
        let decision = ReviewCoordinator.decide(spans: [span(weight: 0.8)])

        XCTAssertTrue(decision.deservesAttention)
        XCTAssertEqual(decision.flagged.count, 1)
    }

    /// The whole point of the split. A mark heavy enough to be worth showing is
    /// not thereby heavy enough to be worth telling the user about.
    func testAMidWeightSpanIsShownButNeverAnnounced() {
        let decision = ReviewCoordinator.decide(spans: [span(weight: 0.6, reason: .namedEntity)])

        XCTAssertFalse(decision.deservesAttention, "a capitalized word must not light the indicator on its own")
        XCTAssertEqual(decision.highlighted.count, 1, "but it is still worth seeing once the review is open")
        XCTAssertTrue(decision.hasAnythingToShow)
    }

    /// A single rule, and no accumulation: twenty light marks are still twenty
    /// light marks. Letting them add up is how a review nobody reads is built.
    func testManyLightSpansStillDoNotEarnTheIndicator() {
        let light = (0..<20).map { _ in span(weight: 0.05, reason: .cleanupEdit(.punctuation)) }
        let decision = ReviewCoordinator.decide(spans: light)

        XCTAssertFalse(decision.deservesAttention)
        XCTAssertTrue(decision.highlighted.isEmpty, "punctuation is below the display threshold too")
    }

    func testFlaggedSpansAreAlwaysAlsoHighlighted() {
        let decision = ReviewCoordinator.decide(
            spans: [
                span(weight: 0.05, reason: .cleanupEdit(.spacing)),
                span(weight: 0.9),
                span(weight: 0.3, reason: .languageSwitch(.english)),
            ]
        )

        XCTAssertEqual(decision.flagged.count, 1)
        XCTAssertEqual(decision.flagged.first?.reason, .number)
        XCTAssertEqual(decision.highlighted.count, 2, "the language switch is shown, the spacing edit is not")
        for span in decision.flagged {
            XCTAssertTrue(decision.highlighted.contains(span), "a flagged span the review does not draw is a dead indicator")
        }
    }

    func testAnEmptyResultIsNeverWorthAnything() {
        XCTAssertEqual(
            ReviewCoordinator.decide(spans: [span(weight: 0.9)], isEmptyResult: true),
            .quiet
        )
    }

    func testTheTwoThresholdsAreTheOnlyKnobs() {
        let spans = [span(weight: 0.4)]

        let strict = ReviewCoordinator.decide(spans: spans, policy: ReviewPolicy(attentionThreshold: 0.8, displayThreshold: 0.3))
        XCTAssertFalse(strict.deservesAttention)
        XCTAssertEqual(strict.highlighted.count, 1)

        let loose = ReviewCoordinator.decide(spans: spans, policy: ReviewPolicy(attentionThreshold: 0.3, displayThreshold: 0.3))
        XCTAssertTrue(loose.deservesAttention)
    }

    /// A display threshold above the attention threshold would hide the marks
    /// that caused the indicator, so the policy refuses to hold that shape.
    func testTheDisplayThresholdCannotRiseAboveTheAttentionThreshold() {
        let policy = ReviewPolicy(attentionThreshold: 0.5, displayThreshold: 0.9)

        XCTAssertEqual(policy.displayThreshold, 0.5)
    }

    /// Determinism: the same inputs give the same answer, every time.
    func testTheDecisionIsDeterministic() {
        let spans = [span(weight: 0.9), span(weight: 0.1, reason: .cleanupEdit(.spacing))]
        let first = ReviewCoordinator.decide(spans: spans)

        for _ in 0..<50 {
            XCTAssertEqual(ReviewCoordinator.decide(spans: spans), first)
        }
    }
}
