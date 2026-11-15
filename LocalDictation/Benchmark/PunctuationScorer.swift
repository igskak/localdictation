#if DEBUG
import Foundation

/// What closes the gap after a word, as far as sentence structure goes.
///
/// Five classes rather than every mark, because these are the decisions a
/// reader notices: whether a sentence ended, whether it asked something, and
/// where a clause paused. A colon or semicolon counts as a pause inside the
/// sentence, the same class as a comma.
enum BoundaryMark: Int, Sendable, CaseIterable, Comparable {
    case unmarked, comma, period, exclamation, question

    var endsSentence: Bool { self == .period || self == .question || self == .exclamation }

    static func < (lhs: BoundaryMark, rhs: BoundaryMark) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Nil for a character that is not punctuation this scorer reads.
    init?(_ character: Character) {
        switch character {
        case "?": self = .question
        case "!": self = .exclamation
        case ".", "…": self = .period
        case ",", ";", ":": self = .comma
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .unmarked: "∅"
        case .comma: ","
        case .period: "."
        case .exclamation: "!"
        case .question: "?"
        }
    }
}

/// One word in alignment form, with the boundary that follows it.
struct PunctuatedWord: Sendable, Equatable {
    /// Normalized the way `TextNormalizer` normalizes for WER, so the
    /// alignment here and the WER alignment agree on what a word is.
    let word: String
    let mark: BoundaryMark
    /// A line break follows this word.
    let paragraphBreak: Bool
}

/// Punctuation and paragraph agreement between a reference and a hypothesis.
///
/// Counts, not rates, so samples pool by addition and a language's score is
/// the sum over its boundaries rather than an average of sample averages.
struct PunctuationScore: Sendable, Equatable {
    struct Pair: Hashable, Sendable {
        let reference: BoundaryMark
        let hypothesis: BoundaryMark
    }

    /// Reference mark against hypothesis mark at every boundary. A reference
    /// word the engine dropped counts as a boundary with no mark, and an
    /// inserted word as a boundary the reference did not have.
    private(set) var counts: [Pair: Int] = [:]
    private(set) var paragraphHits = 0
    private(set) var paragraphMisses = 0
    private(set) var paragraphFalseAlarms = 0

    static let zero = PunctuationScore()

    mutating func record(reference: BoundaryMark, hypothesis: BoundaryMark) {
        counts[Pair(reference: reference, hypothesis: hypothesis), default: 0] += 1
    }

    mutating func recordParagraph(reference: Bool, hypothesis: Bool) {
        switch (reference, hypothesis) {
        case (true, true): paragraphHits += 1
        case (true, false): paragraphMisses += 1
        case (false, true): paragraphFalseAlarms += 1
        case (false, false): break
        }
    }

    static func + (lhs: PunctuationScore, rhs: PunctuationScore) -> PunctuationScore {
        var result = lhs
        for (pair, count) in rhs.counts { result.counts[pair, default: 0] += count }
        result.paragraphHits += rhs.paragraphHits
        result.paragraphMisses += rhs.paragraphMisses
        result.paragraphFalseAlarms += rhs.paragraphFalseAlarms
        return result
    }

    func count(reference: BoundaryMark? = nil, hypothesis: BoundaryMark? = nil) -> Int {
        counts.reduce(0) { total, entry in
            let (pair, count) = entry
            if let reference, pair.reference != reference { return total }
            if let hypothesis, pair.hypothesis != hypothesis { return total }
            return total + count
        }
    }

    /// How many boundaries the reference marks with `mark`.
    func support(_ mark: BoundaryMark) -> Int { count(reference: mark) }

    func recall(_ mark: BoundaryMark) -> Double? {
        let relevant = count(reference: mark)
        return relevant > 0 ? Double(count(reference: mark, hypothesis: mark)) / Double(relevant) : nil
    }

    func precision(_ mark: BoundaryMark) -> Double? {
        let produced = count(hypothesis: mark)
        return produced > 0 ? Double(count(reference: mark, hypothesis: mark)) / Double(produced) : nil
    }

    func f1(_ mark: BoundaryMark) -> Double? {
        Self.harmonic(precision(mark), recall(mark))
    }

    /// Whether a sentence ended where the reference ends one, whatever mark
    /// ended it. Separates "found the boundary" from "chose the right mark".
    var sentenceBoundaryRecall: Double? {
        let relevant = sentenceCount { reference, _ in reference.endsSentence }
        let hits = sentenceCount { $0.endsSentence && $1.endsSentence }
        return relevant > 0 ? Double(hits) / Double(relevant) : nil
    }

    var sentenceBoundaryPrecision: Double? {
        let produced = sentenceCount { _, hypothesis in hypothesis.endsSentence }
        let hits = sentenceCount { $0.endsSentence && $1.endsSentence }
        return produced > 0 ? Double(hits) / Double(produced) : nil
    }

    var sentenceBoundaryF1: Double? {
        Self.harmonic(sentenceBoundaryPrecision, sentenceBoundaryRecall)
    }

    var paragraphRecall: Double? {
        let relevant = paragraphHits + paragraphMisses
        return relevant > 0 ? Double(paragraphHits) / Double(relevant) : nil
    }

    var paragraphPrecision: Double? {
        let produced = paragraphHits + paragraphFalseAlarms
        return produced > 0 ? Double(paragraphHits) / Double(produced) : nil
    }

    private func sentenceCount(_ predicate: (BoundaryMark, BoundaryMark) -> Bool) -> Int {
        counts.reduce(0) { $0 + (predicate($1.key.reference, $1.key.hypothesis) ? $1.value : 0) }
    }

    private static func harmonic(_ precision: Double?, _ recall: Double?) -> Double? {
        guard let precision, let recall else { return nil }
        return precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    }
}

/// Pure punctuation scoring. Words are aligned the way WER aligns them, and
/// the boundary after every aligned word is compared.
enum PunctuationScorer {
    /// Splits text into words carrying the boundary that follows each.
    ///
    /// Words end where `TextNormalizer` would split them: at whitespace and at
    /// every character it strips. A mark between two digits with no space —
    /// `1.450`, `12:30`, `3,5` — is part of a number, not a boundary.
    static func punctuatedWords(
        _ text: String,
        language: SpeechLanguage,
        normalizer: TextNormalizer = .default
    ) -> [PunctuatedWord] {
        let characters = Array(text.precomposedStringWithCanonicalMapping)
        var words: [(word: String, mark: BoundaryMark, paragraphBreak: Bool)] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            let normalized = normalizer.normalize(current, language: language)
            current = ""
            guard !normalized.isEmpty else { return }
            words.append((normalized, .unmarked, false))
        }

        for (index, character) in characters.enumerated() {
            let separates = character.isWhitespace || TextNormalizer.strippedPunctuation.contains(character)
            guard separates else {
                current.append(character)
                continue
            }

            let insideNumber = !character.isWhitespace
                && (current.last?.isNumber ?? false)
                && index + 1 < characters.count
                && characters[index + 1].isNumber
            flush()
            guard !insideNumber, !words.isEmpty else { continue }

            if character.isNewline {
                words[words.count - 1].paragraphBreak = true
            } else if let mark = BoundaryMark(character), mark > words[words.count - 1].mark {
                words[words.count - 1].mark = mark
            }
        }
        flush()

        // A break after the last word is the end of the text, not a paragraph.
        if !words.isEmpty { words[words.count - 1].paragraphBreak = false }
        return words.map { PunctuatedWord(word: $0.word, mark: $0.mark, paragraphBreak: $0.paragraphBreak) }
    }

    static func score(
        reference: String,
        hypothesis: String,
        language: SpeechLanguage,
        normalizer: TextNormalizer = .default
    ) -> PunctuationScore {
        let referenceWords = punctuatedWords(reference, language: language, normalizer: normalizer)
        let hypothesisWords = punctuatedWords(hypothesis, language: language, normalizer: normalizer)
        let operations = TranscriptionScorer.align(
            reference: referenceWords.map(\.word),
            hypothesis: hypothesisWords.map(\.word)
        )

        var score = PunctuationScore()
        for operation in operations {
            switch operation {
            case let .match(reference, hypothesis), let .substitution(reference, hypothesis):
                let expected = referenceWords[reference]
                let produced = hypothesisWords[hypothesis]
                score.record(reference: expected.mark, hypothesis: produced.mark)
                score.recordParagraph(reference: expected.paragraphBreak, hypothesis: produced.paragraphBreak)
            case let .deletion(reference):
                let expected = referenceWords[reference]
                score.record(reference: expected.mark, hypothesis: .unmarked)
                score.recordParagraph(reference: expected.paragraphBreak, hypothesis: false)
            case let .insertion(hypothesis):
                let produced = hypothesisWords[hypothesis]
                score.record(reference: .unmarked, hypothesis: produced.mark)
                score.recordParagraph(reference: false, hypothesis: produced.paragraphBreak)
            }
        }
        return score
    }

    /// The mark the text ends on, `.unmarked` when it runs off the end.
    static func finalMark(_ text: String, language: SpeechLanguage) -> BoundaryMark {
        punctuatedWords(text, language: language).last?.mark ?? .unmarked
    }
}
#endif
