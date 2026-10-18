import Foundation

struct TypedValueRecord: Sendable, Equatable {
    enum Category: String, Sendable, Equatable {
        case number, date, time, currency, percentage, unit
    }

    let category: Category
    /// Locale-independent value used by round-trip and review tests.
    let canonicalValue: String
}

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
        case spokenPunctuation
        case lineBreak
        case paragraphBreak
        case explicitCorrection
        case repetitionRemoval
        case listFormatting
        case numberFormatting
        case dateFormatting
        case timeFormatting
        case currencyFormatting
        case percentageFormatting
        case unitFormatting
        case contextSpacing
        case contextCapitalization
        case contextPunctuation
        case dictionaryCorrection

        var label: String {
            switch self {
            case .spacing: L10n.string("Spacing")
            case .punctuation: L10n.string("Punctuation")
            case .capitalization: L10n.string("Capitalization")
            case .fillerRemoval: L10n.string("Filler removed")
            case .spokenPunctuation: L10n.string("Spoken punctuation")
            case .lineBreak: L10n.string("Line break")
            case .paragraphBreak: L10n.string("Paragraph break")
            case .explicitCorrection: L10n.string("Explicit correction")
            case .repetitionRemoval: L10n.string("Repeated words removed")
            case .listFormatting: L10n.string("List formatting")
            case .numberFormatting: L10n.string("Number formatting")
            case .dateFormatting: L10n.string("Date formatting")
            case .timeFormatting: L10n.string("Time formatting")
            case .currencyFormatting: L10n.string("Currency formatting")
            case .percentageFormatting: L10n.string("Percentage formatting")
            case .unitFormatting: L10n.string("Unit formatting")
            case .contextSpacing: L10n.string("Context spacing")
            case .contextCapitalization: L10n.string("Context capitalization")
            case .contextPunctuation: L10n.string("Context punctuation")
            case .dictionaryCorrection: L10n.string("Dictionary correction")
            }
        }

        /// Whether the edit removed something the speaker actually said.
        ///
        /// Only filler removal does. That distinction is what keeps the review
        /// step from firing on every utterance: adding a closing period is not
        /// the same event as deleting a word.
        var removesSpokenWords: Bool {
            switch self {
            case .fillerRemoval, .explicitCorrection, .repetitionRemoval: true
            default: false
            }
        }
    }

    let kind: Kind
    /// `Character` offsets into the raw transcript.
    let rawRange: Range<Int>
    /// `Character` offsets into the cleaned text.
    let cleanedRange: Range<Int>
    let rawText: String
    let cleanedText: String
    let typedValue: TypedValueRecord?

    init(
        kind: Kind,
        rawRange: Range<Int>,
        cleanedRange: Range<Int>,
        rawText: String,
        cleanedText: String,
        typedValue: TypedValueRecord? = nil
    ) {
        self.kind = kind
        self.rawRange = rawRange
        self.cleanedRange = cleanedRange
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.typedValue = typedValue
    }
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
    private let stages: [Stage]

    private struct Stage: Sendable, Equatable {
        let segments: [Segment]
        let rawLength: Int
        let cleanedLength: Int
    }

    init(segments: [Segment], rawLength: Int, cleanedLength: Int) {
        self.segments = segments
        self.rawLength = rawLength
        self.cleanedLength = cleanedLength
        self.stages = [Stage(segments: segments, rawLength: rawLength, cleanedLength: cleanedLength)]
    }

    private init(stages: [Stage], rawLength: Int, cleanedLength: Int) {
        self.segments = stages.count == 1 ? stages[0].segments : []
        self.rawLength = rawLength
        self.cleanedLength = cleanedLength
        self.stages = stages
    }

    static func identity(length: Int) -> EditMap {
        EditMap(
            segments: length > 0 ? [Segment(raw: 0..<length, cleaned: 0..<length, isEdit: false)] : [],
            rawLength: length,
            cleanedLength: length
        )
    }

    var hasEdits: Bool { stages.contains { $0.segments.contains(where: \.isEdit) } }

    /// Exact composition without reconstructing either text or diffing it.
    /// Each stage keeps its own coordinate system; projections simply walk
    /// the chain forward or backward.
    func composed(with next: EditMap) -> EditMap? {
        guard cleanedLength == next.rawLength else { return nil }
        return EditMap(
            stages: stages + next.stages,
            rawLength: rawLength,
            cleanedLength: next.cleanedLength
        )
    }

    // MARK: - Raw to cleaned

    func cleanedRange(forRaw range: Range<Int>) -> Range<Int> {
        let lower = cleanedStart(forRaw: range.lowerBound)
        let upper = cleanedEnd(forRaw: range.upperBound)
        return lower..<max(lower, upper)
    }

    /// Where a raw offset begins in the cleaned text. An offset that lands
    /// inside a replaced region collapses to the start of that replacement.
    func cleanedStart(forRaw offset: Int) -> Int {
        var value = min(max(offset, 0), rawLength)
        for stage in stages {
            value = Self.cleanedStart(value, in: stage)
        }
        return value
    }

    /// Where a raw offset ends in the cleaned text. An offset that lands inside
    /// a replaced region expands to the end of that replacement, so a span that
    /// touches an edit still covers the whole of it.
    func cleanedEnd(forRaw offset: Int) -> Int {
        var value = min(max(offset, 0), rawLength)
        for stage in stages {
            value = Self.cleanedEnd(value, in: stage)
        }
        return value
    }

    // MARK: - Cleaned to raw

    func rawRange(forCleaned range: Range<Int>) -> Range<Int> {
        let lower = rawStart(forCleaned: range.lowerBound)
        let upper = rawEnd(forCleaned: range.upperBound)
        return lower..<max(lower, upper)
    }

    func rawStart(forCleaned offset: Int) -> Int {
        var value = min(max(offset, 0), cleanedLength)
        for stage in stages.reversed() {
            value = Self.rawStart(value, in: stage)
        }
        return value
    }

    func rawEnd(forCleaned offset: Int) -> Int {
        var value = min(max(offset, 0), cleanedLength)
        for stage in stages.reversed() {
            value = Self.rawEnd(value, in: stage)
        }
        return value
    }

    private static func cleanedStart(_ offset: Int, in stage: Stage) -> Int {
        let offset = min(max(offset, 0), stage.rawLength)
        for segment in stage.segments where segment.raw.upperBound > offset {
            guard segment.raw.lowerBound <= offset else { return segment.cleaned.lowerBound }
            if segment.isEdit { return segment.cleaned.lowerBound }
            return segment.cleaned.lowerBound + (offset - segment.raw.lowerBound)
        }
        return stage.cleanedLength
    }

    private static func cleanedEnd(_ offset: Int, in stage: Stage) -> Int {
        let offset = min(max(offset, 0), stage.rawLength)
        guard offset > 0 else { return 0 }
        for segment in stage.segments.reversed() where segment.raw.lowerBound < offset {
            if segment.isEdit { return segment.cleaned.upperBound }
            return min(segment.cleaned.lowerBound + (offset - segment.raw.lowerBound), segment.cleaned.upperBound)
        }
        return 0
    }

    private static func rawStart(_ offset: Int, in stage: Stage) -> Int {
        let offset = min(max(offset, 0), stage.cleanedLength)
        for segment in stage.segments where segment.cleaned.upperBound > offset {
            guard segment.cleaned.lowerBound <= offset else { return segment.raw.lowerBound }
            if segment.isEdit { return segment.raw.lowerBound }
            return segment.raw.lowerBound + (offset - segment.cleaned.lowerBound)
        }
        return stage.rawLength
    }

    private static func rawEnd(_ offset: Int, in stage: Stage) -> Int {
        let offset = min(max(offset, 0), stage.cleanedLength)
        guard offset > 0 else { return 0 }
        for segment in stage.segments.reversed() where segment.cleaned.lowerBound < offset {
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
    /// The old cleanup contract retained for attribution and comparison.
    /// Context is intentionally absent: this is transcript-derived text only.
    let conservativeText: String?
    let cleaned: String
    let edits: [TextEdit]
    let map: EditMap
    /// The language whose rules were applied. German capitalizes nouns and
    /// Russian does not, so a rule set is only meaningful next to its language.
    let language: SpeechLanguage

    init(
        raw: String,
        conservativeText: String? = nil,
        cleaned: String,
        edits: [TextEdit],
        map: EditMap,
        language: SpeechLanguage
    ) {
        self.raw = raw
        self.conservativeText = conservativeText
        self.cleaned = cleaned
        self.edits = edits
        self.map = map
        self.language = language
    }

    var didChangeText: Bool { raw != cleaned }

    /// Edits that removed words the speaker actually said.
    var wordRemovingEdits: [TextEdit] { edits.filter { $0.kind.removesSpokenWords } }

    static func unchanged(_ text: String, language: SpeechLanguage) -> CleanupResult {
        CleanupResult(
            raw: text,
            conservativeText: nil,
            cleaned: text,
            edits: [],
            map: .identity(length: text.count),
            language: language
        )
    }
}
