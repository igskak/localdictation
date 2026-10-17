import Foundation

struct DictionaryCorrectionTransformer: Sendable {
    func transform(
        _ text: String,
        language: SpeechLanguage,
        glossary: [GlossaryEntry],
        protected: [ProtectedSpan]
    ) -> CleanupResult {
        let entries = glossary
            .filter { $0.language == language && $0.isValid && $0.normalizedReplacement != nil }
            .sorted { ($0.normalizedReplacement?.count ?? 0) > ($1.normalizedReplacement?.count ?? 0) }
        guard !entries.isEmpty else { return .unchanged(text, language: language) }
        let words = WordScanner.words(in: text)
        var candidates: [CleanupReplacement] = []
        for entry in entries {
            guard let trigger = entry.normalizedReplacement else { continue }
            let triggerWords = WordScanner.words(in: trigger).map(\.lowercased)
            guard !triggerWords.isEmpty, triggerWords.count <= words.count else { continue }
            for start in 0...(words.count - triggerWords.count) {
                let candidate = words[start..<(start + triggerWords.count)].map(\.lowercased)
                guard candidate == triggerWords else { continue }
                let range = words[start].range.lowerBound..<words[start + triggerWords.count - 1].range.upperBound
                guard ProtectedSpanDetector.allows(
                    proposed: range,
                    protected: protected,
                    owningWholeSpan: .glossary
                ) else { continue }
                candidates.append(.init(range: range, text: entry.normalizedTerm, kind: .dictionaryCorrection))
            }
        }
        return CleanupTransformation.apply(candidates, to: text, language: language)
    }
}
