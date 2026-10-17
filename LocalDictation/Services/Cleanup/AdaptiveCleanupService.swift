import Foundation

/// Selects the cleanup contract without changing the long-lived conservative
/// implementation. Clean deliberately aliases Conservative until its measured
/// transformers are added by later Phase 9 slices.
struct AdaptiveCleanupService: CleanupService {
    private let conservative = ConservativeCleanupService()
    private let commands = SpokenCommandTransformer()
    private let dictionary = DictionaryCorrectionTransformer()

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
            return append(final, to: result)
        }
    }

    private func append(_ stage: CleanupResult, to result: CleanupResult) -> CleanupResult {
        EditMapComposition.append(stage, to: result) ?? result
    }
}
