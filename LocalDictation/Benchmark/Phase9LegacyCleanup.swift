#if DEBUG
// Frozen Phase 9 baseline from commit 75f4e4984fc8d880f1c76192ba2a91233061d6dc.
// Used only by the benchmark; keep its rules unchanged for comparisons.
import Foundation

/// Selects the cleanup contract without changing the long-lived conservative
/// implementation. Clean deliberately aliases Conservative until its measured
/// transformers are added by later Phase 9 slices.
struct Phase9LegacyCleanupService: CleanupService {
    private let conservative = ConservativeCleanupService()
    private let commands = SpokenCommandTransformer()
    private let dictionary = DictionaryCorrectionTransformer()
    private let corrections = Phase9LegacyCorrectionTransformer()
    private let repetitions = RepetitionTransformer()
    private let lists = Phase9LegacyListTransformer()
    private let typedValues = TypedValueFormatter()
    private let contextCompositor = ContextCompositor()

    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult {
        switch options.level {
        case .verbatim:
            return .unchanged(raw, language: language)
        case .conservative:
            return conservative.clean(raw, language: language, options: options)
        case .clean:
            guard language.isVerified else {
                return conservative.clean(raw, language: language, options: options)
            }
            let conservativeText = conservative.clean(
                raw,
                language: language,
                options: CleanupOptions(level: .conservative, glossary: options.glossary)
            ).cleaned
            var result = conservative.clean(
                raw,
                language: language,
                options: CleanupOptions(
                    level: .clean,
                    glossary: options.glossary,
                    capitalizesSentences: false,
                    addsTerminalPunctuation: false
                )
            )
            result = append(
                commands.transform(
                    result.cleaned,
                    language: language,
                    protected: ProtectedSpanDetector().detect(
                        in: result.cleaned,
                        language: language,
                        glossary: options.glossary
                    )
                ),
                to: result
            )
            result = append(
                dictionary.transform(
                    result.cleaned,
                    language: language,
                    glossary: options.glossary,
                    protected: ProtectedSpanDetector().detect(
                        in: result.cleaned,
                        language: language,
                        glossary: options.glossary
                    )
                ),
                to: result
            )
            result = append(
                corrections.transform(
                    result.cleaned,
                    language: language,
                    protected: ProtectedSpanDetector().detect(
                        in: result.cleaned,
                        language: language,
                        glossary: options.glossary
                    )
                ),
                to: result
            )
            result = append(
                repetitions.transform(
                    result.cleaned,
                    language: language,
                    protected: ProtectedSpanDetector().detect(
                        in: result.cleaned,
                        language: language,
                        glossary: options.glossary
                    )
                ),
                to: result
            )
            result = append(
                lists.transform(
                    result.cleaned,
                    language: language,
                    protected: ProtectedSpanDetector().detect(
                        in: result.cleaned,
                        language: language,
                        glossary: options.glossary
                    )
                ),
                to: result
            )
            result = append(
                typedValues.transform(
                    result.cleaned,
                    language: language,
                    protected: ProtectedSpanDetector().detect(
                        in: result.cleaned,
                        language: language,
                        glossary: options.glossary
                    )
                ),
                to: result
            )
            let final = conservative.clean(
                result.cleaned,
                language: language,
                options: CleanupOptions(
                    level: .clean,
                    glossary: options.glossary,
                    collapsesWhitespace: false,
                    removesFillers: false
                )
            )
            result = append(final, to: result)
            if let context = options.context {
                result = append(
                    contextCompositor.transform(
                        result.cleaned,
                        raw: raw,
                        language: language,
                        context: context,
                        glossary: options.glossary
                    ),
                    to: result
                )
            }
            return CleanupResult(
                raw: result.raw,
                conservativeText: conservativeText,
                cleaned: result.cleaned,
                edits: result.edits,
                map: result.map,
                language: result.language
            )
        }
    }

    private func append(_ stage: CleanupResult, to result: CleanupResult) -> CleanupResult {
        EditMapComposition.append(stage, to: result) ?? result
    }
}

import Foundation

struct Phase9LegacyListTransformer: Sendable {
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

import Foundation

struct Phase9LegacyCorrectionTransformer: Sendable {
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

#endif
