import Foundation

/// One conservative edit cleanup made to the raw transcript.
///
/// The kinds are a closed set on purpose. Phase 3 cleanup may not change
/// wording, word order, numbers, or meaning, so an operation that cannot be
/// described as one of these does not belong in this phase — it would be a
/// rewrite, which `docs/PRODUCT_SCOPE.md` places after the MVP.
struct TextEdit: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case spacing
        case punctuation
        case capitalization
        case fillerRemoval

        var label: String {
            switch self {
            case .spacing: "Spacing"
            case .punctuation: "Punctuation"
            case .capitalization: "Capitalization"
            case .fillerRemoval: "Filler removed"
            }
        }

        /// Whether the edit removed something the speaker actually said.
        ///
        /// Only filler removal does. That distinction is what keeps the review
        /// step from firing on every utterance: adding a closing period is not
        /// the same event as deleting a word.
        var removesSpokenWords: Bool { self == .fillerRemoval }
    }

    let kind: Kind
    /// `Character` offsets into the raw transcript.
    let rawRange: Range<Int>
    /// `Character` offsets into the cleaned text.
    let cleanedRange: Range<Int>
    let rawText: String
    let cleanedText: String
}

/// Translates character ranges between the raw transcript and the cleaned text.
///
/// The map is built while the cleaned string is assembled, so it is exact by
/// construction rather than recovered by diffing afterwards. Round-tripping an
/// untouched range is an invariant the tests assert, not an assumption.
struct EditMap: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let raw: Range<Int>
        let cleaned: Range<Int>
        /// `false` for text carried over verbatim, `true` for a replacement.
        let isEdit: Bool
    }

    let segments: [Segment]
    let rawLength: Int
    let cleanedLength: Int

    static func identity(length: Int) -> EditMap {
        EditMap(
            segments: length > 0 ? [Segment(raw: 0..<length, cleaned: 0..<length, isEdit: false)] : [],
            rawLength: length,
            cleanedLength: length
        )
    }

    var hasEdits: Bool { segments.contains { $0.isEdit } }

    // MARK: - Raw to cleaned

    func cleanedRange(forRaw range: Range<Int>) -> Range<Int> {
        let lower = cleanedStart(forRaw: range.lowerBound)
        let upper = cleanedEnd(forRaw: range.upperBound)
        return lower..<max(lower, upper)
    }

    /// Where a raw offset begins in the cleaned text. An offset that lands
    /// inside a replaced region collapses to the start of that replacement.
    func cleanedStart(forRaw offset: Int) -> Int {
        let offset = min(max(offset, 0), rawLength)
        for segment in segments where segment.raw.upperBound > offset {
            guard segment.raw.lowerBound <= offset else { return segment.cleaned.lowerBound }
            if segment.isEdit { return segment.cleaned.lowerBound }
            return segment.cleaned.lowerBound + (offset - segment.raw.lowerBound)
        }
        return cleanedLength
    }

    /// Where a raw offset ends in the cleaned text. An offset that lands inside
    /// a replaced region expands to the end of that replacement, so a span that
    /// touches an edit still covers the whole of it.
    func cleanedEnd(forRaw offset: Int) -> Int {
        let offset = min(max(offset, 0), rawLength)
        guard offset > 0 else { return 0 }
        for segment in segments.reversed() where segment.raw.lowerBound < offset {
            if segment.isEdit { return segment.cleaned.upperBound }
            return min(segment.cleaned.lowerBound + (offset - segment.raw.lowerBound), segment.cleaned.upperBound)
        }
        return 0
    }

    // MARK: - Cleaned to raw

    func rawRange(forCleaned range: Range<Int>) -> Range<Int> {
        let lower = rawStart(forCleaned: range.lowerBound)
        let upper = rawEnd(forCleaned: range.upperBound)
        return lower..<max(lower, upper)
    }

    func rawStart(forCleaned offset: Int) -> Int {
        let offset = min(max(offset, 0), cleanedLength)
        for segment in segments where segment.cleaned.upperBound > offset {
            guard segment.cleaned.lowerBound <= offset else { return segment.raw.lowerBound }
            if segment.isEdit { return segment.raw.lowerBound }
            return segment.raw.lowerBound + (offset - segment.cleaned.lowerBound)
        }
        return rawLength
    }

    func rawEnd(forCleaned offset: Int) -> Int {
        let offset = min(max(offset, 0), cleanedLength)
        guard offset > 0 else { return 0 }
        for segment in segments.reversed() where segment.cleaned.lowerBound < offset {
            if segment.isEdit { return segment.raw.upperBound }
            return min(segment.raw.lowerBound + (offset - segment.cleaned.lowerBound), segment.raw.upperBound)
        }
        return 0
    }
}

/// The output of conservative cleanup: both texts, every edit, and the map
/// between them. The raw transcript is never mutated and stays recoverable.
struct CleanupResult: Sendable, Equatable {
    let raw: String
    let cleaned: String
    let edits: [TextEdit]
    let map: EditMap
    /// The language whose rules were applied. German capitalizes nouns and
    /// Russian does not, so a rule set is only meaningful next to its language.
    let language: SpeechLanguage

    var didChangeText: Bool { raw != cleaned }

    /// Edits that removed words the speaker actually said.
    var wordRemovingEdits: [TextEdit] { edits.filter { $0.kind.removesSpokenWords } }

    static func unchanged(_ text: String, language: SpeechLanguage) -> CleanupResult {
        CleanupResult(
            raw: text,
            cleaned: text,
            edits: [],
            map: .identity(length: text.count),
            language: language
        )
    }
}
