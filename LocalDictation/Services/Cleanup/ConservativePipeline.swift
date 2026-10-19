import Foundation

/// Keeps the original Conservative primitive available as a benchmark control.
struct ConservativePipeline: CleanupService {
    private let canonicalizer = RealWhisperCanonicalizer()
    private let primitive = ConservativeCleanupService()

    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult {
        let canonical = canonicalizer.transform(raw, language: language, glossary: options.glossary)
        guard canonical.didChangeText else {
            return primitive.clean(raw, language: language, options: options)
        }
        let cleaned = primitive.clean(canonical.cleaned, language: language, options: options)
        return EditMapComposition.append(cleaned, to: canonical) ?? canonical
    }
}
