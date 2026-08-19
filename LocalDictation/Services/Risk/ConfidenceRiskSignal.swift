import Foundation

/// The engine's own uncertainty — the sixth signal, and the last one.
///
/// It is wired up, positioned, and measured like the others, but
/// `RiskWeights.modelConfidence` starts at zero, so it contributes nothing to
/// the review decision until a measurement on real speech earns it a weight.
/// Phase 2 found weak separation between the confidence of correct and
/// incorrect tokens, and negative separation on Russian; that is not a verdict,
/// but it is reason enough not to rest the feature on it.
///
/// Keeping the signal live at weight zero means its spans still appear in the
/// measurement report, so the weight can be raised from evidence rather than
/// from a fresh implementation.
struct ConfidenceRiskSignal: RiskSignal {
    let identifier = "confidence"

    let threshold: Double

    init(threshold: Double = RiskWeights.default.confidenceThreshold) {
        self.threshold = threshold
    }

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        context.tokens.compactMap { token in
            guard let confidence = token.confidence, confidence <= threshold else { return nil }
            guard !token.range.isEmpty else { return nil }
            return RawRiskSpan(reason: .lowConfidence(confidence), range: token.range)
        }
    }
}
