import Foundation

/// One edit-distance alignment step between a reference and a hypothesis.
enum AlignmentOperation: Sendable, Equatable {
    case match(reference: Int, hypothesis: Int)
    case substitution(reference: Int, hypothesis: Int)
    case deletion(reference: Int)
    case insertion(hypothesis: Int)

    var isError: Bool {
        if case .match = self { return false }
        return true
    }
}

/// Substitution/deletion/insertion counts against a reference length.
struct ErrorRate: Sendable, Equatable {
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let referenceCount: Int

    var errors: Int { substitutions + deletions + insertions }

    /// Errors per reference unit. `nil` when the reference is empty, because a
    /// rate against nothing is not a measurement.
    var rate: Double? {
        referenceCount > 0 ? Double(errors) / Double(referenceCount) : nil
    }

    static let zero = ErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceCount: 0)

    static func + (lhs: ErrorRate, rhs: ErrorRate) -> ErrorRate {
        ErrorRate(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            referenceCount: lhs.referenceCount + rhs.referenceCount
        )
    }
}

/// How well an engine's confidence predicts its own mistakes.
///
/// This is the deciding metric of the Phase 2 benchmark. An engine with a good
/// WER but no separation between the confidence of its right and wrong tokens
/// cannot support the product promise, because Phase 3's review step would have
/// nothing to point at.
struct ConfidenceCalibration: Sendable, Equatable {
    let threshold: Double
    let correctCount: Int
    let incorrectCount: Int
    let meanConfidenceWhenCorrect: Double?
    let meanConfidenceWhenIncorrect: Double?
    /// Share of wrong tokens the threshold would have flagged.
    let recall: Double?
    /// Share of correct tokens the threshold would have flagged anyway.
    let falseWarningRate: Double?

    /// Positive means low confidence really does track mistakes.
    /// Around zero, or negative, means the signal is unusable.
    var separation: Double? {
        guard let correct = meanConfidenceWhenCorrect,
              let incorrect = meanConfidenceWhenIncorrect
        else { return nil }
        return correct - incorrect
    }
}

/// Pure scoring. No I/O, no engine, no model — so every number the benchmark
/// reports is reproducible from the corpus text alone.
enum TranscriptionScorer {
    // MARK: - Alignment

    /// Levenshtein alignment with a backtrace, so every metric below derives
    /// from one shared definition of what counts as an error.
    static func align<Element: Equatable>(
        reference: [Element],
        hypothesis: [Element]
    ) -> [AlignmentOperation] {
        let rows = reference.count
        let columns = hypothesis.count

        // costs[r][h] = edit distance between reference[0..<r] and hypothesis[0..<h]
        var costs = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for r in 0...rows { costs[r][0] = r }
        for h in 0...columns { costs[0][h] = h }

        for r in 1...max(rows, 1) where rows > 0 {
            for h in 1...max(columns, 1) where columns > 0 {
                if reference[r - 1] == hypothesis[h - 1] {
                    costs[r][h] = costs[r - 1][h - 1]
                } else {
                    costs[r][h] = 1 + min(
                        costs[r - 1][h - 1], // substitution
                        costs[r - 1][h],     // deletion
                        costs[r][h - 1]      // insertion
                    )
                }
            }
        }

        var operations: [AlignmentOperation] = []
        var r = rows
        var h = columns

        while r > 0 || h > 0 {
            if r > 0, h > 0, reference[r - 1] == hypothesis[h - 1], costs[r][h] == costs[r - 1][h - 1] {
                operations.append(.match(reference: r - 1, hypothesis: h - 1))
                r -= 1
                h -= 1
            } else if r > 0, h > 0, costs[r][h] == costs[r - 1][h - 1] + 1 {
                operations.append(.substitution(reference: r - 1, hypothesis: h - 1))
                r -= 1
                h -= 1
            } else if r > 0, costs[r][h] == costs[r - 1][h] + 1 {
                operations.append(.deletion(reference: r - 1))
                r -= 1
            } else {
                operations.append(.insertion(hypothesis: h - 1))
                h -= 1
            }
        }

        return operations.reversed()
    }

    // MARK: - Rates

    static func errorRate(from operations: [AlignmentOperation], referenceCount: Int) -> ErrorRate {
        var substitutions = 0
        var deletions = 0
        var insertions = 0

        for operation in operations {
            switch operation {
            case .match: break
            case .substitution: substitutions += 1
            case .deletion: deletions += 1
            case .insertion: insertions += 1
            }
        }

        return ErrorRate(
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            referenceCount: referenceCount
        )
    }

    static func wordErrorRate(
        reference: String,
        hypothesis: String,
        language: SpeechLanguage,
        normalizer: TextNormalizer = .default
    ) -> ErrorRate {
        let referenceWords = normalizer.words(reference, language: language)
        let hypothesisWords = normalizer.words(hypothesis, language: language)
        let operations = align(reference: referenceWords, hypothesis: hypothesisWords)
        return errorRate(from: operations, referenceCount: referenceWords.count)
    }

    static func characterErrorRate(
        reference: String,
        hypothesis: String,
        language: SpeechLanguage,
        normalizer: TextNormalizer = .default
    ) -> ErrorRate {
        let referenceCharacters = normalizer.characters(reference, language: language)
        let hypothesisCharacters = normalizer.characters(hypothesis, language: language)
        let operations = align(reference: referenceCharacters, hypothesis: hypothesisCharacters)
        return errorRate(from: operations, referenceCount: referenceCharacters.count)
    }

    /// Word error rate restricted to the reference words the predicate selects.
    ///
    /// This is how the product-critical rates are computed: the alignment is the
    /// same as for plain WER, but only the selected reference positions count,
    /// so "we got the sentence right but the amount wrong" is visible instead of
    /// being averaged away.
    ///
    /// Insertions are attributed to the reference word they follow, since an
    /// inserted word has no reference position of its own.
    static func errorRate(
        reference: String,
        hypothesis: String,
        language: SpeechLanguage,
        normalizer: TextNormalizer = .default,
        selecting predicate: (String) -> Bool
    ) -> ErrorRate {
        let referenceWords = normalizer.words(reference, language: language)
        let hypothesisWords = normalizer.words(hypothesis, language: language)
        let operations = align(reference: referenceWords, hypothesis: hypothesisWords)

        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var selectedCount = 0
        var previousReferenceIndex: Int?

        for operation in operations {
            switch operation {
            case let .match(reference: index, hypothesis: _):
                previousReferenceIndex = index
                if predicate(referenceWords[index]) { selectedCount += 1 }

            case let .substitution(reference: index, hypothesis: _):
                previousReferenceIndex = index
                if predicate(referenceWords[index]) {
                    selectedCount += 1
                    substitutions += 1
                }

            case let .deletion(reference: index):
                previousReferenceIndex = index
                if predicate(referenceWords[index]) {
                    selectedCount += 1
                    deletions += 1
                }

            case .insertion:
                if let previous = previousReferenceIndex, predicate(referenceWords[previous]) {
                    insertions += 1
                }
            }
        }

        return ErrorRate(
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            referenceCount: selectedCount
        )
    }

    // MARK: - Calibration

    /// Aligns a transcript's tokens against the reference and asks whether the
    /// engine's own confidence separated its correct tokens from its wrong ones.
    static func calibration(
        of transcript: Transcript,
        reference: String,
        language: SpeechLanguage,
        threshold: Double,
        normalizer: TextNormalizer = .default
    ) -> ConfidenceCalibration {
        let referenceWords = normalizer.words(reference, language: language)
        // Token order is preserved by normalization, so the normalized forms map
        // back onto the original tokens position by position.
        let hypothesisTokens = transcript.tokens.filter {
            !normalizer.normalize($0.text, language: language).isEmpty
        }
        let hypothesisWords = hypothesisTokens.map { normalizer.normalize($0.text, language: language) }
        let operations = align(reference: referenceWords, hypothesis: hypothesisWords)

        var correct: [Double] = []
        var incorrect: [Double] = []
        var correctCount = 0
        var incorrectCount = 0
        var flaggedIncorrect = 0
        var flaggedCorrect = 0

        func record(hypothesisIndex: Int, isCorrect: Bool) {
            guard hypothesisIndex < hypothesisTokens.count else { return }
            let confidence = hypothesisTokens[hypothesisIndex].confidence
            if isCorrect {
                correctCount += 1
                if let confidence {
                    correct.append(confidence)
                    if confidence <= threshold { flaggedCorrect += 1 }
                }
            } else {
                incorrectCount += 1
                if let confidence {
                    incorrect.append(confidence)
                    if confidence <= threshold { flaggedIncorrect += 1 }
                }
            }
        }

        for operation in operations {
            switch operation {
            case let .match(reference: _, hypothesis: index):
                record(hypothesisIndex: index, isCorrect: true)
            case let .substitution(reference: _, hypothesis: index):
                record(hypothesisIndex: index, isCorrect: false)
            case let .insertion(hypothesis: index):
                record(hypothesisIndex: index, isCorrect: false)
            case .deletion:
                // A deleted word produced no token, so it carries no confidence.
                break
            }
        }

        return ConfidenceCalibration(
            threshold: threshold,
            correctCount: correctCount,
            incorrectCount: incorrectCount,
            meanConfidenceWhenCorrect: correct.isEmpty ? nil : correct.reduce(0, +) / Double(correct.count),
            meanConfidenceWhenIncorrect: incorrect.isEmpty ? nil : incorrect.reduce(0, +) / Double(incorrect.count),
            recall: incorrect.isEmpty ? nil : Double(flaggedIncorrect) / Double(incorrect.count),
            falseWarningRate: correct.isEmpty ? nil : Double(flaggedCorrect) / Double(correct.count)
        )
    }
}

/// Selectors for the categories the product actually promises to protect.
///
/// Named entities are deliberately absent: the usual "capitalized mid-sentence"
/// heuristic is meaningless in German, where every noun is capitalized. Entity
/// scoring needs a tagged corpus, not a heuristic, and is left to be added with
/// one rather than shipped broken.
enum CriticalTokens {
    private static let currencySymbols: Set<Character> = ["€", "$", "£", "₴", "₽", "¥"]

    static func containsDigit(_ word: String) -> Bool {
        word.contains { $0.isNumber }
    }

    static func isCurrency(_ word: String) -> Bool {
        word.contains { currencySymbols.contains($0) }
            || ["euro", "eur", "cent", "dollar", "usd", "евро", "євро", "гривень", "рублей"].contains(word)
    }

    /// Digits, currency, and the spelled-out number words of the four supported
    /// languages — the fragments that turn a good transcript into a silent error.
    static func isNumeric(_ word: String) -> Bool {
        containsDigit(word) || isCurrency(word) || numberWords.contains(word)
    }

    static let numberWords: Set<String> = [
        // German
        "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "elf", "zwölf", "zwanzig", "dreißig", "vierzig", "fünfzig", "hundert", "tausend", "million",
        // English
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million",
        // Russian
        "ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять",
        "двадцать", "тридцать", "сорок", "пятьдесят", "сто", "тысяча", "миллион",
        // Ukrainian
        "нуль", "одна", "одне", "два", "три", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять",
        "десять", "двадцять", "тридцять", "сорок", "п'ятдесят", "сто", "тисяча", "мільйон",
    ]
}
