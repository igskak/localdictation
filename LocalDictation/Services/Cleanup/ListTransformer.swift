import Foundation

struct ListTransformer: Sendable {
    private static let markers: [SpeechLanguage: [[String]]] = [
        .english: [["first", "one"], ["second", "two"], ["third", "three"]],
        .german: [["erstens", "eins"], ["zweitens", "zwei"], ["drittens", "drei"]],
        .russian: [["во-первых", "один"], ["во-вторых", "два"], ["в-третьих", "три"]],
        .ukrainian: [["по-перше", "один"], ["по-друге", "два"], ["по-третє", "три"]],
    ]
    private static let bulletMarkers: [SpeechLanguage: Set<String>] = [
        .english: ["bullet"],
        .german: ["aufzählungspunkt"],
        .russian: ["маркер"],
        .ukrainian: ["маркер"],
    ]

    func transform(_ text: String, language: SpeechLanguage, protected: [ProtectedSpan]) -> CleanupResult {
        guard let languageMarkers = Self.markers[language], let colon = Array(text).lastIndex(of: ":") else {
            return .unchanged(text, language: language)
        }
        let words = WordScanner.words(in: text).filter { word in
            word.range.lowerBound > colon
                && !protected.contains(where: { span in
                    span.category != .number
                        && (span.range.overlaps(word.range) || span.range == word.range)
                })
        }
        var orderedStarts: [(word: TextWord, order: Int)] = []
        for word in words {
            guard let order = languageMarkers.firstIndex(where: { $0.contains(word.lowercased) }) else { continue }
            if orderedStarts.isEmpty || order == orderedStarts.count { orderedStarts.append((word, order)) }
        }
        if orderedStarts.count >= 2, orderedStarts[0].order == 0 {
            return format(
                orderedStarts.map(\.word),
                marker: { "\($0 + 1)." },
                after: colon,
                in: text,
                language: language
            )
        }
        let bullets = words.filter { Self.bulletMarkers[language]?.contains($0.lowercased) == true }
        guard bullets.count >= 2 else { return .unchanged(text, language: language) }
        return format(bullets, marker: { _ in "-" }, after: colon, in: text, language: language)
    }

    private func format(
        _ starts: [TextWord],
        marker: (Int) -> String,
        after colon: Int,
        in text: String,
        language: SpeechLanguage
    ) -> CleanupResult {
        let source = Array(text)
        var replacements: [CleanupReplacement] = []
        for index in starts.indices {
            let contentStart = starts[index].range.upperBound
            let contentEnd = index + 1 < starts.count ? starts[index + 1].range.lowerBound : source.count
            let item = String(source[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return .unchanged(text, language: language) }
            var lower = index == 0 ? colon + 1 : starts[index].range.lowerBound
            if index > 0, lower > 0, source[lower - 1].isWhitespace { lower -= 1 }
            replacements.append(
                .init(range: lower..<starts[index].range.upperBound, text: "\n\(marker(index))", kind: .listFormatting)
            )
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }
}
