import Foundation

/// Explicit fixture policies can exercise the planner. Production languages
/// remain disabled until their independent real-speech measurements exist.
struct StructuralBoundaryPolicy: Sendable {
    let sentenceGap: TimeInterval
    let minimumClauseTokens: Int
    let allowedClauseEndings: Set<String>
    let paragraphGap: TimeInterval?
    let minimumParagraphTokens: Int

    init(sentenceGap: TimeInterval, minimumClauseTokens: Int, allowedClauseEndings: Set<String>,
         paragraphGap: TimeInterval? = nil, minimumParagraphTokens: Int = 3) {
        self.sentenceGap = sentenceGap
        self.minimumClauseTokens = minimumClauseTokens
        self.allowedClauseEndings = allowedClauseEndings
        self.paragraphGap = paragraphGap
        self.minimumParagraphTokens = minimumParagraphTokens
    }

    static func measuredPolicy(for language: SpeechLanguage) -> StructuralBoundaryPolicy? {
        // No Phase 9.1 real-speech threshold has been measured yet.
        nil
    }
}

struct StructuralBoundaryCandidate: Sendable, Equatable {
    let rawAnchor: Int
    let cleanedAnchor: Int
    let cleanedResume: Int
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
                                    cleanedResume: rightMapped.lowerBound, gap: gap, ruleIdentifier: "measured-clause-ending"))
        }
        return candidates
    }

    func paragraphs(raw: String, result: CleanupResult, evidence: CleanupTimingEvidence,
                    policy: StructuralBoundaryPolicy, category: ApplicationCategory,
                    protected: [ProtectedSpan]) -> [StructuralBoundaryCandidate] {
        guard category != .codeTerminal, result.raw == raw,
              let threshold = policy.paragraphGap, threshold.isFinite, threshold > policy.sentenceGap,
              policy.minimumParagraphTokens > 0,
              policy.minimumParagraphTokens <= evidence.tokens.count / 2,
              CleanupTimingEvidence.validated(evidence.tokens, raw: raw) != nil else { return [] }
        let source = Array(raw)
        let current = Array(result.cleaned)
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "z", "b", "u", "т", "д"]
        var candidates: [StructuralBoundaryCandidate] = []
        for index in (policy.minimumParagraphTokens - 1)..<(evidence.tokens.count - policy.minimumParagraphTokens) {
            let left = evidence.tokens[index]
            let right = evidence.tokens[index + 1]
            let text = String(source[left.rawRange])
            let stem = text.dropLast()
            let gap = right.start - left.end
            let between = source[left.rawRange.upperBound..<right.rawRange.lowerBound]
            guard gap >= threshold, text.hasSuffix("."), stem.count > 1,
                  stem.allSatisfy(\.isLetter), !abbreviations.contains(stem.lowercased()),
                  !between.isEmpty, between.allSatisfy({ $0.isWhitespace && !$0.isNewline }),
                  !protected.contains(where: { $0.range.overlaps(left.rawRange) || $0.range.overlaps(right.rawRange) })
            else { continue }
            let lm = result.map.cleanedRange(forRaw: left.rawRange)
            let rm = result.map.cleanedRange(forRaw: right.rawRange)
            guard lm.upperBound <= current.count, rm.upperBound <= current.count, lm.upperBound < rm.lowerBound,
                  result.map.rawRange(forCleaned: lm) == left.rawRange,
                  result.map.rawRange(forCleaned: rm) == right.rawRange,
                  Array(current[lm]) == Array(source[left.rawRange]), Array(current[rm]) == Array(source[right.rawRange]),
                  current[lm.upperBound..<rm.lowerBound].allSatisfy({ $0.isWhitespace && !$0.isNewline }) else { continue }
            candidates.append(.init(rawAnchor: left.rawRange.upperBound, cleanedAnchor: lm.upperBound,
                                    cleanedResume: rm.lowerBound, gap: gap, ruleIdentifier: "measured-completed-sentence"))
        }
        return candidates
    }
}

/// Materializes approved candidates as punctuation-only edits in the current
/// representation. The caller composes this stage with the raw edit map.
struct StructuralBoundaryTransformer: Sendable {
    func paragraphs(_ candidates: [StructuralBoundaryCandidate], in text: String, language: SpeechLanguage) -> CleanupResult {
        let replacements = candidates.map {
            CleanupReplacement(range: $0.cleanedAnchor..<$0.cleanedResume, text: "\n\n", kind: .inferredParagraphBreak)
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }

    func sentences(_ candidates: [StructuralBoundaryCandidate], in text: String, language: SpeechLanguage) -> CleanupResult {
        let replacements = candidates.map {
            CleanupReplacement(range: $0.cleanedAnchor..<$0.cleanedAnchor, text: ".", kind: .inferredPunctuation)
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
