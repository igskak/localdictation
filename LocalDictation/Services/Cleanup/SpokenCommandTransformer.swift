import Foundation

struct SpokenCommandTransformer: Sendable {
    func transform(
        _ text: String,
        language: SpeechLanguage,
        protected: [ProtectedSpan]
    ) -> CleanupResult {
        guard let rules = VerifiedLanguageCleanupRules.commands[language] else {
            return .unchanged(text, language: language)
        }
        let words = WordScanner.words(in: text)
        let source = Array(text)
        let orderedRules = rules.sorted { $0.phrase.count > $1.phrase.count }
        var replacements: [CleanupReplacement] = []
        var index = 0
        while index < words.count {
            guard let rule = orderedRules.first(where: { rule in
                guard index + rule.phrase.count <= words.count else { return false }
                let candidate = words[index..<(index + rule.phrase.count)].map(\.lowercased)
                return candidate == rule.phrase && (!rule.finalPositionOnly || index + rule.phrase.count == words.count)
            }) else {
                index += 1
                continue
            }
            var range = words[index].range.lowerBound..<words[index + rule.phrase.count - 1].range.upperBound
            if rule.kind == .lineBreak || rule.kind == .paragraphBreak {
                if range.lowerBound > 0, source[range.lowerBound - 1].isWhitespace { range = (range.lowerBound - 1)..<range.upperBound }
                while range.upperBound < source.count, source[range.upperBound].isWhitespace {
                    range = range.lowerBound..<(range.upperBound + 1)
                }
            }
            if ProtectedSpanDetector.allows(proposed: range, protected: protected) {
                replacements.append(.init(range: range, text: rule.output, kind: rule.kind))
            }
            index += rule.phrase.count
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
