import Foundation

struct ListTransformer: Sendable {
    private static let markers: [SpeechLanguage: [[String]]] = [
        .english: [["first", "one"], ["second", "two"], ["third", "three"]],
        .german: [["erstens", "eins"], ["zweitens", "zwei"], ["drittens", "drei"]],
        .russian: [["во-первых", "один"], ["во-вторых", "два"], ["в-третьих", "три"]],
        .ukrainian: [["по-перше", "один"], ["по-друге", "два"], ["по-третє", "три"]],
    ]

    func transform(_ text: String, language: SpeechLanguage, protected: [ProtectedSpan]) -> CleanupResult {
        guard let languageMarkers = Self.markers[language], let colon = Array(text).lastIndex(of: ":") else {
            return .unchanged(text, language: language)
        }
        let words = WordScanner.words(in: text).filter { $0.range.lowerBound > colon }
        var starts: [(word: TextWord, order: Int)] = []
        for word in words {
            guard let order = languageMarkers.firstIndex(where: { $0.contains(word.lowercased) }) else { continue }
            if starts.isEmpty || order == starts.count { starts.append((word, order)) }
        }
        guard starts.count >= 2, starts[0].order == 0 else { return .unchanged(text, language: language) }
        let source = Array(text)
        var replacements: [CleanupReplacement] = []
        for index in starts.indices {
            let contentStart = starts[index].word.range.upperBound
            let contentEnd = index + 1 < starts.count ? starts[index + 1].word.range.lowerBound : source.count
            let item = String(source[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return .unchanged(text, language: language) }
            var lower = index == 0 ? colon + 1 : starts[index].word.range.lowerBound
            if index > 0, lower > 0, source[lower - 1].isWhitespace { lower -= 1 }
            replacements.append(
                .init(range: lower..<starts[index].word.range.upperBound, text: "\n\(index + 1).", kind: .listFormatting)
            )
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
