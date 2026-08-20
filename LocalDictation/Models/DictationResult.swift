import Foundation

/// Everything Phase 3 knows about one utterance.
///
/// Assembled once, when the transcript arrives, and then read. Keeping the raw
/// transcript, the cleaned text, every edit, every span, and the decision in a
/// single value is what makes raw-transcript recovery free: the raw text is not
/// reconstructed later, it was never thrown away.
struct DictationResult: Sendable, Equatable {
    let transcript: Transcript
    let cleanup: CleanupResult
    /// Every span the engine produced, including the ones the policy prices
    /// below both thresholds. Those reach neither the indicator nor the review;
    /// they exist so a measurement can see the whole engine, not the part that
    /// survived a cut.
    let spans: [RiskSpan]
    let decision: ReviewDecision

    var rawText: String { cleanup.raw }
    var cleanedText: String { cleanup.cleaned }
    var profile: LanguageProfile { transcript.profile }
    /// Whether this result is worth pointing at. The only thing that lights the
    /// indicator, and the only thing that keeps the recording alive past the
    /// moment the text is ready.
    var deservesAttention: Bool { decision.deservesAttention }
    /// The marks that earned the indicator.
    var flaggedSpans: [RiskSpan] { decision.flagged }
    /// The marks shown inside the review, a superset of `flaggedSpans`.
    var highlightedSpans: [RiskSpan] { decision.highlighted }
    /// Whether opening the review would show the user anything.
    var hasAnythingToReview: Bool { decision.hasAnythingToShow && !isEmpty }

    var isEmpty: Bool { cleanup.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text the user takes away, given whether they asked for the raw
    /// transcript back.
    func text(preferringRaw preferRaw: Bool) -> String {
        preferRaw ? rawText : cleanedText
    }
}

/// Non-content summary of the Phase 3 stages, for developer diagnostics.
///
/// Counts, weights, and kinds only. As with `TranscriptDiagnostics`, no
/// recognized text is copied in here, so nothing in this struct can reach a
/// log line.
struct RiskDiagnostics: Sendable, Equatable {
    let editCount: Int
    let editKinds: [String]
    let spanCount: Int
    let flaggedSpanCount: Int
    let spanCategories: [String]
    let maximumWeight: Double
    let highlightedSpanCount: Int
    let deservesAttention: Bool

    init(_ result: DictationResult) {
        editCount = result.cleanup.edits.count
        editKinds = result.cleanup.edits.map { $0.kind.rawValue }.sorted()
        spanCount = result.spans.count
        flaggedSpanCount = result.flaggedSpans.count
        spanCategories = result.spans.map { $0.reason.category }.sorted()
        maximumWeight = result.spans.map(\.weight).max() ?? 0
        highlightedSpanCount = result.highlightedSpans.count
        deservesAttention = result.deservesAttention
    }
}
