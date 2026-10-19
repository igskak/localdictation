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
                guard ProtectedSpanDetector.allows(proposed: offsets, protected: protected),
                      !ProtectedSpanDetector.overlapsGlossary(offsets, in: raw, language: language, glossary: glossary) else { continue }
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
                guard !ProtectedSpanDetector.overlapsGlossary(offsets, in: raw, language: language, glossary: glossary) else { continue }
                let compact = String(source[offsets]).replacingOccurrences(of: " ", with: "")
                replacements.append(.init(range: offsets, text: compact, kind: .surfaceNormalization))
            }
        }
        // English percentage typography joins an already-rendered value and
        // symbol. Other verified locales retain their conventional spacing.
        if language == .english, let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_./:@-])[0-9]+(?:[.,][0-9]+)? +%(?![\p{L}\p{N}_./:@-])"#
        ) {
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                let lower = raw.distance(from: raw.startIndex, to: range.lowerBound)
                let upper = raw.distance(from: raw.startIndex, to: range.upperBound)
                let offsets = lower..<upper
                guard !ProtectedSpanDetector.overlapsGlossary(offsets, in: raw, language: language, glossary: glossary) else { continue }
                replacements.append(.init(range: offsets, text: String(source[offsets]).replacingOccurrences(of: " ", with: ""),
                                          kind: .surfaceNormalization))
            }
        }
        // English prefix currencies conventionally attach to a complete numeric
        // amount. Only the separator changes; ambiguous identifiers stay fenced.
        if language == .english, let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_./:@$£-])[$£] +[0-9]+(?:\.[0-9]{1,2})?(?![\p{L}\p{N}_.,/:@%-])"#
        ) {
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                let lower = raw.distance(from: raw.startIndex, to: range.lowerBound)
                let upper = raw.distance(from: raw.startIndex, to: range.upperBound)
                let offsets = lower..<upper
                guard !ProtectedSpanDetector.overlapsGlossary(offsets, in: raw, language: language, glossary: glossary) else { continue }
                replacements.append(.init(range: offsets, text: String(source[offsets]).replacingOccurrences(of: " ", with: ""),
                                          kind: .surfaceNormalization))
            }
        }
        // Join the degree sign to C/F only for a complete numeric temperature.
        // Keep the value-to-unit spacing and every digit exactly as spoken.
        if let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_./:@-])[0-9]+(?:[.,][0-9]+)? +° +[CF](?![\p{L}\p{N}_./:@-])"#
        ) {
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                let offsets = raw.distance(from: raw.startIndex, to: range.lowerBound)..<raw.distance(from: raw.startIndex, to: range.upperBound)
                guard !ProtectedSpanDetector.overlapsGlossary(offsets, in: raw, language: language, glossary: glossary) else { continue }
                let text = String(source[offsets])
                guard let degree = text.firstIndex(of: "°"), let unit = text.last else { continue }
                let prefix = text[...degree]
                replacements.append(.init(range: offsets, text: String(prefix) + String(unit), kind: .surfaceNormalization))
            }
        }
        // Require explicit segment provenance as well as identical positive
        // intervals. Equal timestamps alone do not prove a duplicated token.
        if let timing, timing.boundaryDuplicatePolicyEnabled,
           CleanupTimingEvidence.validated(timing.tokens, raw: raw) != nil,
           timing.tokens.count >= 2 {
            for index in 1..<timing.tokens.count {
                let left = timing.tokens[index - 1]
                let right = timing.tokens[index]
                guard right.segmentBoundaryBefore,
                      left.start == right.start, left.end == right.end, left.end > left.start,
                      left.rawRange.upperBound < right.rawRange.lowerBound,
                      source[left.rawRange.upperBound..<right.rawRange.lowerBound].allSatisfy(\.isWhitespace),
                      String(source[left.rawRange]) == String(source[right.rawRange]),
                      !protected.contains(where: { $0.range.overlaps(left.rawRange) || $0.range.overlaps(right.rawRange) }),
                      !ProtectedSpanDetector.overlapsGlossary(left.rawRange, in: raw, language: language, glossary: glossary),
                      !ProtectedSpanDetector.overlapsGlossary(right.rawRange, in: raw, language: language, glossary: glossary)
                else { continue }
                replacements.append(.init(range: left.rawRange.upperBound..<right.rawRange.upperBound,
                                          text: "", kind: .boundaryDuplicateRemoval))
            }
        }
        return CleanupTransformation.apply(replacements, to: raw, language: language)
    }
}
