import Foundation

struct ExplicitCorrectionTransformer: Sendable {
    private static let markers: [SpeechLanguage: [[String]]] = [
        .english: [["correction"], ["i", "mean"]],
        .german: [["korrektur"], ["ich", "meine"]],
        .russian: [["поправка"], ["я", "имею", "в", "виду"]],
        .ukrainian: [["виправлення"], ["я", "маю", "на", "увазі"]],
    ]

    func transform(
        _ text: String,
        language: SpeechLanguage,
        protected: [ProtectedSpan]
    ) -> CleanupResult {
        guard let markers = Self.markers[language] else { return .unchanged(text, language: language) }
        let words = WordScanner.words(in: text)
        let source = Array(text)
        var replacements: [CleanupReplacement] = []

        for marker in markers.sorted(by: { $0.count > $1.count }) {
            guard words.count >= marker.count + 2 else { continue }
            for start in 1..<(words.count - marker.count) {
                guard words[start..<(start + marker.count)].map(\.lowercased) == marker else { continue }
                let prior = words[start - 1]
                let replacement = words[start + marker.count]
                var deletion = prior.range.lowerBound..<words[start + marker.count - 1].range.upperBound
                if deletion.upperBound < source.count, source[deletion.upperBound] == "," {
                    deletion = deletion.lowerBound..<(deletion.upperBound + 1)
                }
                while deletion.upperBound < source.count, source[deletion.upperBound].isWhitespace {
                    deletion = deletion.lowerBound..<(deletion.upperBound + 1)
                }

                let conflicts = protected.filter { $0.range.overlaps(prior.range) || $0.range == prior.range }
                if conflicts.isEmpty {
                    replacements.append(.init(range: deletion, text: "", kind: .explicitCorrection))
                    continue
                }
                let replacementCategories = Set(
                    protected
                        .filter { $0.range.overlaps(replacement.range) || $0.range == replacement.range }
                        .map(\.category)
                )
                guard conflicts.allSatisfy({ replacementCategories.contains($0.category) }) else { continue }
                replacements.append(.init(range: deletion, text: "", kind: .explicitCorrection))
            }
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
