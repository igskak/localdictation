import Foundation

/// What a sentence's words say about it being a question.
enum QuestionCue: Int, Sendable, Comparable {
    case none
    /// Opens with a question word and has no comma: "Когда ты будешь дома".
    case interrogative
    /// Carries a question particle where only a question puts one: Ukrainian
    /// "Чи…" first, Russian "…ли" among the first three words, "разве",
    /// "неужели", "хіба", "невже".
    case particle

    static func < (lhs: QuestionCue, rhs: QuestionCue) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Lexical question cues for Russian and Ukrainian.
///
/// Narrow on purpose. A sentence that opens with a question word and then has
/// a comma is usually a clause ("Когда закончишь, напиши"), and "ли" after a
/// comma is an indirect question ("Он спросил, сможем ли мы"), so neither
/// counts. Those are exactly the cases the punctuation corpus checks for.
enum QuestionCues {
    static let interrogatives: [SpeechLanguage: Set<String>] = [
        .russian: [
            "что", "кто", "где", "когда", "куда", "откуда", "почему", "зачем", "как", "сколько",
            "чей", "чья", "чьё", "чье", "чьи", "какой", "какая", "какое", "какие", "каким", "какую",
            "каких", "какого", "какому", "какими", "который", "которая", "которое", "которые",
        ],
        .ukrainian: [
            "що", "хто", "де", "коли", "куди", "звідки", "чому", "навіщо", "нащо", "як", "скільки",
            "чий", "чия", "чиє", "чиї", "який", "яка", "яке", "які", "якого", "якій", "яким", "якою",
            "яку", "яких", "котрий", "котра", "котре", "котрі",
        ],
    ]

    /// Openings that make a question word a conjunction or a concession.
    static let clauseOpenings: [SpeechLanguage: Set<String>] = [
        .russian: ["как только", "как будто", "как бы", "что бы", "кто бы", "где бы", "когда бы",
                   "что касается", "как раз", "как обычно", "как всегда"],
        .ukrainian: ["як тільки", "як би", "що б", "хто б", "де б", "коли б", "що стосується",
                     "як завжди", "як зазвичай"],
    ]

    static let leadingParticles: [SpeechLanguage: Set<String>] = [
        .russian: ["разве", "неужели", "неужто"],
        .ukrainian: ["чи", "хіба", "невже"],
    ]

    static func cue(words: [String], hasComma: Bool, language: SpeechLanguage) -> QuestionCue {
        guard let first = words.first else { return .none }
        if leadingParticles[language]?.contains(first) == true { return .particle }
        if language == .russian, !hasComma, words.prefix(3).dropFirst().contains("ли") { return .particle }
        guard !hasComma, words.count >= 2, interrogatives[language]?.contains(first) == true else { return .none }
        let opening = words.prefix(2).joined(separator: " ")
        if clauseOpenings[language]?.contains(opening) == true { return .none }
        return .interrogative
    }
}

/// When the melody of an ending is evidence of a question: the voice ends
/// above the speaker's own median, with its high point late.
///
/// Read off the synthetic punctuation corpus (232 sentence ends, 2026-11-15):
/// every statement in all four languages ended at least 2.8 semitones below
/// the median, while half the Russian, German and English questions ended
/// above it. A rise in the middle of the ending is not used: the Ukrainian
/// voice rises inside statements as often as inside questions, and a rule
/// built on that put `?` on a third of its statements. The upper bound keeps
/// an octave error of the tracker from passing as a rise.
///
/// Synthetic speech is the weak point; recalibrate on the live corpus.
struct QuestionProsodyPolicy: Sendable, Equatable {
    /// Semitones above the speaker's median the ending has to finish at.
    var minimumTail: Float
    var maximumTail: Float
    /// How late in the ending its highest frame has to be, 0 to 1.
    var minimumPeakPosition: Float

    static let calibrated = QuestionProsodyPolicy(minimumTail: 1.0, maximumTail: 11.0, minimumPeakPosition: 0.5)

    func isQuestionLike(_ ending: SentenceEndingProsody) -> Bool {
        ending.tail >= minimumTail && ending.tail <= maximumTail && ending.peakPosition >= minimumPeakPosition
    }
}

/// Structure Clean adds on top of what the recognizer wrote: question marks
/// the recognizer missed in Russian and Ukrainian, and paragraphs at long
/// pauses.
///
/// Both are punctuation-only edits, recorded as `inferredPunctuation` and
/// `inferredParagraphBreak`, so the review can show every one of them and no
/// word can change.
struct StructurePass: Sendable {
    struct Policy: Sendable, Equatable {
        /// Languages whose missed questions are repaired. German and English
        /// are absent because Whisper already wrote every question there.
        var questionLanguages: Set<SpeechLanguage> = [.russian, .ukrainian]
        var prosody = QuestionProsodyPolicy.calibrated
        /// A pause this long after a finished sentence starts a paragraph.
        var paragraphGap: TimeInterval = 1.0
        /// Neither side of a paragraph break may be shorter than this.
        var minimumParagraphTokens = 5

        static let standard = Policy()
    }

    let policy: Policy

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    // MARK: - Paragraphs

    func paragraphs(
        raw: String,
        result: CleanupResult,
        timing: CleanupTimingEvidence?,
        language: SpeechLanguage,
        category: ApplicationCategory,
        protected: [ProtectedSpan]
    ) -> CleanupResult? {
        guard language.isVerified, let timing else { return nil }
        let boundaries = StructuralBoundaryPolicy(
            sentenceGap: min(0.6, policy.paragraphGap / 2),
            minimumClauseTokens: 4,
            allowedClauseEndings: [],
            paragraphGap: policy.paragraphGap,
            minimumParagraphTokens: policy.minimumParagraphTokens
        )
        let candidates = StructuralBoundaryPlanner().paragraphs(
            raw: raw, result: result, evidence: timing, policy: boundaries,
            category: category, protected: protected
        )
        guard !candidates.isEmpty else { return nil }
        return StructuralBoundaryTransformer().paragraphs(candidates, in: result.cleaned, language: language)
    }

    // MARK: - Questions

    /// The sentences of the cleaned text that should end in `?` and do not.
    func questions(
        result: CleanupResult,
        timing: CleanupTimingEvidence?,
        prosody: ProsodyEvidence?,
        language: SpeechLanguage
    ) -> CleanupResult? {
        guard policy.questionLanguages.contains(language) else { return nil }
        let text = Array(result.cleaned)
        let words = WordScanner.words(in: result.cleaned)
        guard !words.isEmpty else { return nil }

        var replacements: [CleanupReplacement] = []
        var sentence: [TextWord] = []
        for (position, word) in words.enumerated() {
            sentence.append(word)
            let terminator = Self.terminator(after: word, in: text)
            let isLast = position == words.count - 1
            guard terminator != nil || isLast else { continue }
            defer { sentence.removeAll() }

            // Only a period, or nothing at the very end, is open to change.
            if let terminator, text[terminator] != "." { continue }
            if terminator == nil, !isLast { continue }
            guard let first = sentence.first else { continue }

            let span = first.range.lowerBound..<word.range.upperBound
            let hasComma = text[span].contains(",")
            let cue = QuestionCues.cue(words: sentence.map(\.lowercased), hasComma: hasComma, language: language)
            let ending = Self.ending(of: word, result: result, timing: timing, prosody: prosody)
            guard Self.decide(cue: cue, ending: ending, policy: policy.prosody) else { continue }

            let range = terminator.map { $0..<($0 + 1) } ?? (word.range.upperBound..<word.range.upperBound)
            replacements.append(CleanupReplacement(range: range, text: "?", kind: .inferredPunctuation))
        }
        guard !replacements.isEmpty else { return nil }
        return CleanupTransformation.apply(replacements, to: result.cleaned, language: language)
    }

    static func decide(cue: QuestionCue, ending: SentenceEndingProsody?, policy: QuestionProsodyPolicy) -> Bool {
        switch cue {
        // Wh-questions fall at the end in both languages, so their melody is
        // no evidence either way; the words decide.
        case .particle, .interrogative: true
        case .none: ending.map(policy.isQuestionLike) ?? false
        }
    }

    /// The offset of the terminator closing the sentence that ends with
    /// `word`, skipping closing quotes and brackets, or nil when the next
    /// thing is another word.
    private static func terminator(after word: TextWord, in text: [Character]) -> Int? {
        var index = word.range.upperBound
        while index < text.count, ["»", "\"", "”", "“", ")", "]"].contains(text[index]) { index += 1 }
        guard index < text.count, [".", "!", "?", "…"].contains(text[index]) else { return nil }
        return index
    }

    /// The melody at the end of `word`, found through the edit map and the
    /// recognizer's timing for the raw token underneath it.
    private static func ending(
        of word: TextWord,
        result: CleanupResult,
        timing: CleanupTimingEvidence?,
        prosody: ProsodyEvidence?
    ) -> SentenceEndingProsody? {
        guard let timing, let prosody else { return nil }
        let raw = result.map.rawRange(forCleaned: word.range)
        guard let token = timing.tokens.last(where: { $0.rawRange.overlaps(raw) }) else { return nil }
        return prosody.ending(at: token.end)
    }
}
