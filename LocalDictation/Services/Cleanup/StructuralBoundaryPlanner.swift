import Foundation

/// Explicit fixture policies can exercise the planner. Production languages
/// remain disabled until their independent real-speech measurements exist.
struct StructuralBoundaryPolicy: Sendable {
    let sentenceGap: TimeInterval
    let minimumClauseTokens: Int
    let allowedClauseEndings: Set<String>

    static func measuredPolicy(for language: SpeechLanguage) -> StructuralBoundaryPolicy? {
        // No Phase 9.1 real-speech threshold has been measured yet.
        nil
    }
}

struct StructuralBoundaryCandidate: Sendable, Equatable {
    let rawAnchor: Int
    let cleanedAnchor: Int
    let gap: TimeInterval
    let ruleIdentifier: String
}

/// Produces candidates only; it neither changes words nor turns candidates on
/// in production. Raw anchors are projected through the existing edit map.
struct StructuralBoundaryPlanner: Sendable {
    func sentences(raw: String, result: CleanupResult, evidence: CleanupTimingEvidence, policy: StructuralBoundaryPolicy, protected: [ProtectedSpan]) -> [StructuralBoundaryCandidate] {
        let source = Array(raw)
        let current = Array(result.cleaned)
        guard result.raw == raw, policy.sentenceGap.isFinite, policy.sentenceGap > 0,
              policy.minimumClauseTokens > 0, evidence.tokens.count >= policy.minimumClauseTokens + 1,
              CleanupTimingEvidence.validated(evidence.tokens, raw: raw) != nil else { return [] }
        var candidates: [StructuralBoundaryCandidate] = []
        for index in (policy.minimumClauseTokens - 1)..<(evidence.tokens.count - 1) {
            let left = evidence.tokens[index]
            let right = evidence.tokens[index + 1]
            let gap = right.start - left.end
            guard gap >= policy.sentenceGap,
                  left.rawRange.count > 1,
                  source[left.rawRange].allSatisfy(\.isLetter),
                  source[right.rawRange].allSatisfy(\.isLetter),
                  source[left.rawRange.upperBound..<right.rawRange.lowerBound].allSatisfy(\.isWhitespace),
                  !protected.contains(where: { $0.range.overlaps(left.rawRange) || $0.range.overlaps(right.rawRange) }),
                  policy.allowedClauseEndings.contains(String(source[left.rawRange]).lowercased()) else { continue }
            let leftMapped = result.map.cleanedRange(forRaw: left.rawRange)
            let rightMapped = result.map.cleanedRange(forRaw: right.rawRange)
            guard leftMapped.upperBound <= current.count, rightMapped.upperBound <= current.count,
                  leftMapped.upperBound <= rightMapped.lowerBound,
                  result.map.rawRange(forCleaned: leftMapped) == left.rawRange,
                  result.map.rawRange(forCleaned: rightMapped) == right.rawRange,
                  Array(current[leftMapped]) == Array(source[left.rawRange]),
                  Array(current[rightMapped]) == Array(source[right.rawRange]),
                  current[leftMapped.upperBound..<rightMapped.lowerBound].allSatisfy(\.isWhitespace)
            else { continue }
            candidates.append(.init(rawAnchor: left.rawRange.upperBound, cleanedAnchor: leftMapped.upperBound,
                                    gap: gap, ruleIdentifier: "measured-clause-ending"))
        }
        return candidates
    }
}

/// Materializes approved candidates as punctuation-only edits in the current
/// representation. The caller composes this stage with the raw edit map.
struct StructuralBoundaryTransformer: Sendable {
    func sentences(_ candidates: [StructuralBoundaryCandidate], in text: String, language: SpeechLanguage) -> CleanupResult {
        let replacements = candidates.map {
            CleanupReplacement(range: $0.cleanedAnchor..<$0.cleanedAnchor, text: ".", kind: .inferredPunctuation)
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
