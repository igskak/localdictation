import Foundation

/// What a result's risk marks are worth saying, and how loudly.
///
/// Phase 3 had one threshold doing two jobs: choosing what to highlight, and
/// deciding whether to stand between the user and their document. Coupling
/// them is what made the marks expensive. A capitalized word in mid-sentence
/// is worth a highlight — it is not worth an interruption, and pricing it as
/// though it were is exactly what teaches people to dismiss the strip without
/// reading it. The one real error then goes through with all the others.
///
/// Phase 5 separates the two questions, because insertion no longer waits for
/// anybody:
///
/// - `attentionThreshold` decides whether the app says anything at all. It is
///   deliberately high, and it is the only number that can cost the user's
///   attention. Nothing below it may ever be the reason they are told to look.
/// - `displayThreshold` decides what is highlighted once the user has already
///   chosen to look. It is low, because a mark on a page opened on purpose
///   costs nothing — it is the answer to a question that was just asked.
struct ReviewPolicy: Sendable, Equatable {
    var attentionThreshold: Double
    var displayThreshold: Double

    init(attentionThreshold: Double = 0.8, displayThreshold: Double = 0.3) {
        self.attentionThreshold = attentionThreshold
        // A display threshold above the attention threshold would hide the very
        // spans that caused the indicator to light.
        self.displayThreshold = min(displayThreshold, attentionThreshold)
    }

    static let `default` = ReviewPolicy()

    func deservesAttention(_ span: RiskSpan) -> Bool { span.weight >= attentionThreshold }
    func isWorthHighlighting(_ span: RiskSpan) -> Bool { span.weight >= displayThreshold }
}

/// What one result's marks add up to.
///
/// Two lists rather than one, because the review answers two different
/// questions and always did — Phase 3 simply had no way to say so. `flagged`
/// is why the user was told to look; `highlighted` is what they see when they
/// do, and it includes marks that would never have earned the telling.
struct ReviewDecision: Sendable, Equatable {
    /// Spans at or above the attention threshold. A non-empty list is exactly
    /// the condition that lights the indicator — nothing else does.
    let flagged: [RiskSpan]
    /// Spans worth highlighting inside the review. A superset of `flagged`.
    let highlighted: [RiskSpan]

    /// Nothing worth saying, and nothing worth showing. The recording's job is
    /// over at this moment rather than at the end of the interaction.
    static let quiet = ReviewDecision(flagged: [], highlighted: [])

    var deservesAttention: Bool { !flagged.isEmpty }
    /// Whether opening the review would show the user anything at all.
    var hasAnythingToShow: Bool { !highlighted.isEmpty }
}

/// Prices a set of spans against the policy.
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
        guard !isEmptyResult else { return .quiet }
        return ReviewDecision(
            flagged: spans.filter(policy.deservesAttention),
            highlighted: spans.filter(policy.isWorthHighlighting)
        )
    }
}
