import Foundation

/// Thresholds and introduction words are provided only by a measured policy.
struct ImplicitListPolicy: Sendable {
    let introductionWords: Set<String>
    let pauseBeforeFirst: TimeInterval
    let pauseAfterList: TimeInterval

    static func measuredPolicy(for language: SpeechLanguage) -> Self? {
#if WITNESS_PHASE_9_1_PREVIEW
        let introductions: [SpeechLanguage: Set<String>] = [
            .english: ["items", "shopping", "steps", "tasks"],
            .german: ["aufgaben", "einkauf", "punkte", "schritte"],
            .russian: ["задачи", "покупки", "пункты", "шаги"],
            .ukrainian: ["завдання", "покупки", "пункти", "кроки"],
        ]
        guard let words = introductions[language] else { return nil }
        return Self(introductionWords: words, pauseBeforeFirst: 0.6, pauseAfterList: 0.9)
#else
        return nil
#endif
    }
}

/// A deliberately narrow two-item candidate: all anchors must survive prior
/// stages exactly, and a measured pause must delimit both ends of the list.
struct ImplicitListTransformer: Sendable {
    private static let markers: [SpeechLanguage: [String]] = [
        .english: ["first", "second"], .german: ["erstens", "zweitens"],
        .russian: ["во-первых", "во-вторых"], .ukrainian: ["по-перше", "по-друге"],
    ]

    func transform(raw: String, result: CleanupResult, evidence: CleanupTimingEvidence,
                   language: SpeechLanguage, policy: ImplicitListPolicy,
                   protected: [ProtectedSpan]) -> CleanupResult {
        guard let markers = Self.markers[language], result.raw == raw,
              policy.pauseBeforeFirst.isFinite, policy.pauseBeforeFirst > 0,
              policy.pauseAfterList.isFinite, policy.pauseAfterList > 0,
              CleanupTimingEvidence.validated(evidence.tokens, raw: raw) != nil else {
            return .unchanged(result.cleaned, language: language)
        }
        let tokens = evidence.tokens
        let source = Array(raw)
        let current = Array(result.cleaned)
        guard tokens.count >= 6 else { return .unchanged(result.cleaned, language: language) }
        let words = tokens.map { String(source[$0.rawRange]).lowercased() }
        // An exact introduction, two sequential markers and at least one word
        // per item are required. Do not consume a third marker or trailing text.
        guard policy.introductionWords.contains(words[0]), words[1] == markers[0],
              let second = words.indices.dropFirst(3).first(where: { words[$0] == markers[1] }),
              second + 2 < tokens.count,
              words.filter({ markers.contains($0) }).count == 2,
              tokens[1].start - tokens[0].end >= policy.pauseBeforeFirst else {
            return .unchanged(result.cleaned, language: language)
        }
        guard let tail = ((second + 2)..<tokens.count).first(where: {
            tokens[$0].start - tokens[$0 - 1].end >= policy.pauseAfterList
        }) else { return .unchanged(result.cleaned, language: language) }
        let anchors = [tokens[0], tokens[1], tokens[second], tokens[tail - 1], tokens[tail]]
        guard !anchors.contains(where: { token in protected.contains(where: { $0.range.overlaps(token.rawRange) }) }) else {
            return .unchanged(result.cleaned, language: language)
        }
        let projected = anchors.map { result.map.cleanedRange(forRaw: $0.rawRange) }
        guard zip(anchors, projected).allSatisfy({ token, range in
            range.upperBound <= current.count && result.map.rawRange(forCleaned: range) == token.rawRange
                && Array(current[range]) == Array(source[token.rawRange])
        }) else { return .unchanged(result.cleaned, language: language) }
        guard projected[0].upperBound < projected[1].lowerBound,
              projected[1].upperBound <= projected[2].lowerBound,
              projected[2].upperBound <= projected[3].lowerBound,
              projected[3].upperBound < projected[4].lowerBound else {
            return .unchanged(result.cleaned, language: language)
        }
        let firstGap = projected[0].upperBound..<projected[1].lowerBound
        let secondStart = projected[2].lowerBound
        let tailGap = projected[3].upperBound..<projected[4].lowerBound
        guard !firstGap.isEmpty, !tailGap.isEmpty,
              current[firstGap].allSatisfy({ $0.isWhitespace && !$0.isNewline }),
              current[tailGap].allSatisfy({ $0.isWhitespace && !$0.isNewline }),
              secondStart > 0, current[secondStart - 1].isWhitespace else {
            return .unchanged(result.cleaned, language: language)
        }
        return CleanupTransformation.apply([
            .init(range: firstGap.lowerBound..<projected[1].upperBound, text: "\n1.", kind: .listFormatting),
            .init(range: (secondStart - 1)..<projected[2].upperBound, text: "\n2.", kind: .listFormatting),
            .init(range: tailGap, text: "\n\n", kind: .inferredParagraphBreak),
        ], to: result.cleaned, language: language)
    }
}
