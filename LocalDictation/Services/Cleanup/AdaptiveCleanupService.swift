import Foundation

/// Selects the cleanup contract without changing the long-lived conservative
/// implementation. Clean deliberately aliases Conservative until its measured
/// transformers are added by later Phase 9 slices.
struct AdaptiveCleanupService: CleanupService {
    private let conservative = ConservativeCleanupService()

    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult {
        switch options.level {
        case .verbatim:
            return .unchanged(raw, language: language)
        case .conservative, .clean:
            return conservative.clean(raw, language: language, options: options)
        }
    }
}
