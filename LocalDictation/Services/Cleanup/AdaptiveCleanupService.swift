import Foundation

/// Selects the cleanup contract without changing the long-lived conservative
/// implementation. Clean deliberately aliases Conservative until its measured
/// transformers are added by later Phase 9 slices.
struct AdaptiveCleanupService: CleanupService {
    private let conservative = ConservativePipeline()
    private let commands = SpokenCommandTransformer()
    private let dictionary = DictionaryCorrectionTransformer()
    private let corrections = ExplicitCorrectionTransformer()
    private let repetitions = RepetitionTransformer()
    private let lists = ListTransformer()
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
