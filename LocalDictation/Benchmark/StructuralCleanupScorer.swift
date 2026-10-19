#if DEBUG
import Foundation

/// Diagnostics over synthetic fixtures or the consented local corpus only.
enum StructuralCleanupScorer {
    static func conservativeLexicallyPreserved(_ result: CleanupResult) -> Bool {
        let removable = result.edits.filter { $0.kind == .fillerRemoval || $0.kind == .boundaryDuplicateRemoval }
        // An exception is accepted only for actual declared filler vocabulary,
        // or for a separately attributed boundary-duplicate edit.
        for edit in removable where edit.kind == .fillerRemoval {
            let words = WordScanner.words(in: edit.rawText)
            guard !words.isEmpty,
                  words.allSatisfy({ ConservativeCleanupService.fillers[result.language, default: []].contains($0.lowercased) })
            else { return false }
        }
        let removed = CleanupTransformation.apply(removable.map {
            CleanupReplacement(range: $0.rawRange, text: "", kind: $0.kind)
        }, to: result.raw, language: result.language).cleaned
        let canonicalizer = RealWhisperCanonicalizer()
        let expected = canonicalizer.transform(removed, language: result.language, glossary: []).cleaned
        let actual = canonicalizer.transform(result.cleaned, language: result.language, glossary: []).cleaned
        return WordScanner.words(in: expected).map(\.lowercased) == WordScanner.words(in: actual).map(\.lowercased)
    }

    static func isIdempotent(_ result: CleanupResult, service: any CleanupService, options: CleanupOptions) -> Bool {
        var nextOptions = options
        // Both are anchored to the original utterance, not the cleaned text.
        nextOptions.timing = nil
        nextOptions.context = nil
        return service.clean(result.cleaned, language: result.language, options: nextOptions).cleaned == result.cleaned
    }
}
#endif
