import Foundation

struct RepetitionTransformer: Sendable {
    private static let literalAdjacentWords: [SpeechLanguage: Set<String>] = [
        .english: ["very", "had", "that"],
        .german: ["sehr", "dass"],
        .russian: ["очень", "что"],
        .ukrainian: ["дуже", "що"],
    ]

    func transform(
        _ text: String,
        language: SpeechLanguage,
        protected: [ProtectedSpan]
    ) -> CleanupResult {
        let words = WordScanner.words(in: text)
        guard words.count >= 2 else { return .unchanged(text, language: language) }
        var replacements: [CleanupReplacement] = []
        var index = 0
        while index < words.count - 1 {
            var matched = false
            for width in stride(from: min(3, (words.count - index) / 2), through: 1, by: -1) {
                let first = words[index..<(index + width)]
                let second = words[(index + width)..<(index + 2 * width)]
                guard first.map(\.lowercased) == second.map(\.lowercased) else { continue }
                if width == 1, Self.literalAdjacentWords[language, default: []].contains(first.first!.lowercased) {
                    continue
                }
                let source = Array(text)
                let separator = String(source[first.last!.range.upperBound..<second.first!.range.lowerBound])
                guard !separator.contains(where: { ".!?…".contains($0) }) else { continue }
                let removal = first.first!.range.lowerBound..<second.first!.range.lowerBound
                if !ProtectedSpanDetector.allows(proposed: removal, protected: protected) { continue }
                replacements.append(.init(range: removal, text: "", kind: .repetitionRemoval))
                index += width * 2
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
