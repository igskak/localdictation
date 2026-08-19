import Foundation

/// When the review step earns the interruption.
///
/// `docs/PHASE_3.md` requires an explicit, testable policy rather than an
/// accumulated set of conditions, because a risk engine that marks everything
/// is worse than none: it trains the user to dismiss the strip, and then the
/// one real error goes through.
///
/// The policy is therefore a single rule with a single number. A span is
/// *flagged* when its weight reaches the threshold; review is shown when at
/// least one span is flagged. Everything below the threshold is informational —
/// visible inside a review that happens for another reason, never the cause of
/// one.
struct ReviewPolicy: Sendable, Equatable {
    var flagThreshold: Double

    init(flagThreshold: Double = 0.5) {
        self.flagThreshold = flagThreshold
    }

    static let `default` = ReviewPolicy()

    func isFlagged(_ span: RiskSpan) -> Bool { span.weight >= flagThreshold }
}

enum ReviewDecision: Sendable, Equatable {
    /// Nothing worth saying. The result is done, no interruption, and the
    /// audio is released at this moment rather than at the end of the
    /// interaction.
    case noReviewNeeded
    case review(flagged: [RiskSpan])

    var requiresReview: Bool {
        if case .review = self { return true }
        return false
    }

    var flaggedSpans: [RiskSpan] {
        if case let .review(flagged) = self { return flagged }
        return []
    }
}

/// How a shown review ended.
enum ReviewOutcome: String, Sendable, Equatable {
    case accepted
    case dismissed
}

/// Decides between "done" and "show review".
///
/// A pure function of its inputs, and tested as one. It performs no side
/// effects and holds no state, so the decision cannot depend on anything that
/// is not visible in a test.
enum ReviewCoordinator {
    static func decide(
        spans: [RiskSpan],
        policy: ReviewPolicy = .default,
        isEmptyResult: Bool = false
    ) -> ReviewDecision {
        guard !isEmptyResult else { return .noReviewNeeded }
        let flagged = spans.filter(policy.isFlagged)
        return flagged.isEmpty ? .noReviewNeeded : .review(flagged: flagged)
    }
}
