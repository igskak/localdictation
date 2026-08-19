import Foundation

/// Near-misses on the user's own vocabulary.
///
/// An exact match produces nothing: the term came out right, and marking it
/// would spend the false-warning budget on a success. A word one or two edits
/// away from a term the user cared enough to add is the strong case — that is
/// what a misrecognized product name or customer name looks like.
struct GlossaryRiskSignal: RiskSignal {
    let identifier = "glossary"

    /// Distance is capped relative to term length so short terms cannot match
    /// half the dictionary: "Ada" and "Ada" only, never "Ada" and "and".
    static func allowedDistance(forTermLength length: Int) -> Int {
        switch length {
        case ..<4: 1
        case ..<8: 2
        default: 3
        }
    }

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        let terms = context.glossary.filter { context.profile.contains($0.language) }
        guard !terms.isEmpty else { return [] }

        var spans: [RawRiskSpan] = []

        for word in context.words {
            let candidate = word.lowercased
            var best: (term: String, distance: Int)?

            for entry in terms {
                let term = entry.term.lowercased()
                guard !term.isEmpty else { continue }
                if term == candidate {
                    // The term is present and correct; nothing to warn about,
                    // and no weaker near-miss may override that.
                    best = nil
                    break
                }
                let limit = Self.allowedDistance(forTermLength: term.count)
                guard let distance = EditDistance.distance(candidate, term, limit: limit), distance > 0 else { continue }
                if let current = best {
                    if distance < current.distance { best = (entry.term, distance) }
                } else {
                    best = (entry.term, distance)
                }
            }

            if let best {
                spans.append(RawRiskSpan(reason: .glossaryNearMiss(term: best.term), range: word.range))
            }
        }

        return spans
    }
}
