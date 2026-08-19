import Foundation

/// Everything cleanup touched.
///
/// By definition this is text the app changed and the user did not say, which
/// is why `docs/PHASE_3.md` counts it as a risk signal at all. The weight,
/// not the signal, is what keeps it proportionate: `RiskWeights` prices a
/// deleted filler as a real event and a closing period as almost nothing, so
/// the review step is not triggered by punctuation on every single utterance.
struct CleanupEditRiskSignal: RiskSignal {
    let identifier = "cleanup"

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        context.edits.map { edit in
            RawRiskSpan(reason: .cleanupEdit(edit.kind), range: edit.rawRange)
        }
    }
}
