import Foundation

/// Closed surface repairs; never interprets spoken commands or changes words.
struct RealWhisperCanonicalizer: Sendable {
    private static let compounds: [SpeechLanguage: [(String, String)]] = [
        .russian: [("во - первых", "во-первых"), ("во - вторых", "во-вторых"), ("в - третьих", "в-третьих")],
        .ukrainian: [("по - перше", "по-перше"), ("по - друге", "по-друге"), ("по - третє", "по-третє")],
    ]

    func transform(_ raw: String, language: SpeechLanguage, glossary: [GlossaryEntry], timing: CleanupTimingEvidence? = nil) -> CleanupResult {
        guard language.isVerified else { return .unchanged(raw, language: language) }
        let protected = ProtectedSpanDetector().detect(in: raw, language: language, glossary: glossary)
        let source = Array(raw)
        var replacements: [CleanupReplacement] = []
        for (variant, canonical) in Self.compounds[language, default: []] {
            let escaped = NSRegularExpression.escapedPattern(for: variant)
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_/@.])" + escaped + "(?![\\p{L}\\p{N}_/@.])", options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                let lower = raw.distance(from: raw.startIndex, to: range.lowerBound)
                let upper = raw.distance(from: raw.startIndex, to: range.upperBound)
                let offsets = lower..<upper
                guard ProtectedSpanDetector.allows(proposed: offsets, protected: protected) else { continue }
                // Preserve the speaker's capitalization; only spaces around the hyphen change.
                let spelling = String(source[offsets]).replacingOccurrences(of: " - ", with: "-")
                guard spelling.lowercased() == canonical else { continue }
                replacements.append(.init(range: offsets, text: spelling, kind: .surfaceNormalization))
            }
        }
        // Only complete 24-hour clock shapes qualify; identifiers, paths,
        // decimals and glossary entries are fences around the complete span.
        if let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_./:@-])(?:[01]?[0-9]|2[0-3]) +: +[0-5][0-9](?![\p{L}\p{N}_./:@-])"#
        ) {
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                let lower = raw.distance(from: raw.startIndex, to: range.lowerBound)
                let upper = raw.distance(from: raw.startIndex, to: range.upperBound)
                let offsets = lower..<upper
                guard !protected.contains(where: { $0.category == .glossary && $0.range.overlaps(offsets) }) else { continue }
                let compact = String(source[offsets]).replacingOccurrences(of: " ", with: "")
                replacements.append(.init(range: offsets, text: compact, kind: .surfaceNormalization))
            }
        }
        // Identical positive-duration intervals are the narrowest reliable
        // segment-overlap evidence. A zero-duration timestamp proves nothing.
        if let timing, CleanupTimingEvidence.validated(timing.tokens, raw: raw) != nil,
           timing.tokens.count >= 2 {
            for index in 1..<timing.tokens.count {
                let left = timing.tokens[index - 1]
                let right = timing.tokens[index]
                guard left.start == right.start, left.end == right.end, left.end > left.start,
                      source[left.rawRange.upperBound..<right.rawRange.lowerBound].allSatisfy(\.isWhitespace),
                      String(source[left.rawRange]) == String(source[right.rawRange]),
                      !protected.contains(where: { $0.range.overlaps(left.rawRange) || $0.range.overlaps(right.rawRange) })
                else { continue }
                replacements.append(.init(range: left.rawRange.upperBound..<right.rawRange.upperBound,
                                          text: "", kind: .boundaryDuplicateRemoval))
            }
        }
        return CleanupTransformation.apply(replacements, to: raw, language: language)
    }
}
