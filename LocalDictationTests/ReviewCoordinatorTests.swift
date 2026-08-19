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

    func testNothingMarkedMeansNoInterruption() {
        XCTAssertEqual(ReviewCoordinator.decide(spans: []), .noReviewNeeded)
    }

    func testASpanAtTheThresholdIsFlagged() {
        let decision = ReviewCoordinator.decide(spans: [span(weight: 0.5)])

        XCTAssertTrue(decision.requiresReview)
        XCTAssertEqual(decision.flaggedSpans.count, 1)
    }

    /// The single rule: below the threshold is informational, never a cause.
    func testManyLightSpansStillDoNotTriggerAReview() {
        let light = (0..<20).map { _ in span(weight: 0.05, reason: .cleanupEdit(.punctuation)) }

        XCTAssertEqual(
            ReviewCoordinator.decide(spans: light),
            .noReviewNeeded,
            "accumulating punctuation must never add up to an interruption"
        )
    }

    func testOnlyFlaggedSpansAreCarriedIntoTheReview() {
        let decision = ReviewCoordinator.decide(
            spans: [
                span(weight: 0.05, reason: .cleanupEdit(.spacing)),
                span(weight: 0.8),
                span(weight: 0.3, reason: .languageSwitch(.english)),
            ]
        )

        XCTAssertEqual(decision.flaggedSpans.count, 1)
        XCTAssertEqual(decision.flaggedSpans.first?.reason, .number)
    }

    func testAnEmptyResultIsNeverWorthAReview() {
        XCTAssertEqual(
            ReviewCoordinator.decide(spans: [span(weight: 0.9)], isEmptyResult: true),
            .noReviewNeeded
        )
    }

    func testThePolicyThresholdIsTheOnlyKnob() {
        let spans = [span(weight: 0.4)]

        XCTAssertEqual(ReviewCoordinator.decide(spans: spans, policy: ReviewPolicy(flagThreshold: 0.5)), .noReviewNeeded)
        XCTAssertTrue(ReviewCoordinator.decide(spans: spans, policy: ReviewPolicy(flagThreshold: 0.3)).requiresReview)
    }

    /// Determinism: the same inputs give the same answer, every time.
    func testTheDecisionIsDeterministic() {
        let spans = [span(weight: 0.8), span(weight: 0.1, reason: .cleanupEdit(.spacing))]
        let first = ReviewCoordinator.decide(spans: spans)

        for _ in 0..<50 {
            XCTAssertEqual(ReviewCoordinator.decide(spans: spans), first)
        }
    }
}
