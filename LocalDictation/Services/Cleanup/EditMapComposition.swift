import Foundation

enum EditMapComposition {
    /// Composes a raw-to-current result with one current-to-next stage while
    /// retaining provenance in raw/final coordinates.
    static func append(_ stage: CleanupResult, to accumulated: CleanupResult) -> CleanupResult? {
        guard stage.raw == accumulated.cleaned,
              stage.language == accumulated.language,
              let map = accumulated.map.composed(with: stage.map)
        else { return nil }

        let carried = accumulated.edits.map { edit in
            TextEdit(
                kind: edit.kind,
                rawRange: edit.rawRange,
                cleanedRange: stage.map.cleanedRange(forRaw: edit.cleanedRange),
                rawText: edit.rawText,
                cleanedText: slice(stage.cleaned, stage.map.cleanedRange(forRaw: edit.cleanedRange))
            )
        }
        let introduced = stage.edits.map { edit in
            TextEdit(
                kind: edit.kind,
                rawRange: accumulated.map.rawRange(forCleaned: edit.rawRange),
                cleanedRange: edit.cleanedRange,
                rawText: slice(accumulated.raw, accumulated.map.rawRange(forCleaned: edit.rawRange)),
                cleanedText: edit.cleanedText
            )
        }

        return CleanupResult(
            raw: accumulated.raw,
            cleaned: stage.cleaned,
            edits: carried + introduced,
            map: map,
            language: stage.language
        )
    }

    private static func slice(_ text: String, _ range: Range<Int>) -> String {
        let characters = Array(text)
        guard range.lowerBound >= 0, range.upperBound <= characters.count else { return "" }
        return String(characters[range])
    }
}
