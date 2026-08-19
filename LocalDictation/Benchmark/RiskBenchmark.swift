#if DEBUG
import Foundation

/// One word of a hypothesis, positioned in the text the risk engine marked.
private struct ScoredWord {
    let normalized: String
    let range: Range<Int>
}

/// Risk-engine scores for one sample.
struct RiskSampleResult: Sendable, Equatable {
    let audio: String
    let language: SpeechLanguage
    let profile: LanguageProfile
    let reference: String
    let hypothesis: String
    let cleaned: String

    /// Wrong words the engine emitted whose reference counterpart is a number,
    /// an amount, or a date — the errors the product exists to catch.
    let criticalErrors: Int
    let criticalErrorsMarked: Int
    /// Critical reference words that produced no token at all. No rule can mark
    /// what is absent; counted separately rather than hidden in the denominator.
    let criticalWordsDropped: Int

    let wordCount: Int
    let correctWordCount: Int
    /// Flagged spans that touch no wrong word.
    let falseWarnings: Int
    let falseWarningsByCategory: [String: Int]

    /// Differences between raw and cleaned text that filler removal does not
    /// explain. Cleanup that changed meaning would show up here.
    let unexplainedCleanupChanges: Int
    let editKinds: [String]
    let requiresReview: Bool
}

/// Aggregate over a language or the whole corpus.
struct RiskAggregate: Sendable, Equatable {
    let sampleCount: Int
    let criticalErrors: Int
    let criticalErrorsMarked: Int
    let criticalWordsDropped: Int
    let wordCount: Int
    let correctWordCount: Int
    let falseWarnings: Int
    let falseWarningsByCategory: [String: Int]
    let unexplainedCleanupChanges: Int
    let reviewedSampleCount: Int

    /// Of the critical errors a rule could reach, how many did it mark?
    /// `nil` when the corpus proves no such error exists — a recall over zero
    /// errors is not a measurement.
    var recall: Double? {
        criticalErrors > 0 ? Double(criticalErrorsMarked) / Double(criticalErrors) : nil
    }

    /// Marks per hundred words that sit on correct text.
    var falseWarningDensity: Double? {
        wordCount > 0 ? Double(falseWarnings) * 100 / Double(wordCount) : nil
    }

    /// Share of words cleanup carried through unchanged in meaning.
    var semanticPreservation: Double? {
        wordCount > 0 ? 1 - Double(unexplainedCleanupChanges) / Double(wordCount) : nil
    }

    /// How often the review step interrupts at all.
    var reviewRate: Double? {
        sampleCount > 0 ? Double(reviewedSampleCount) / Double(sampleCount) : nil
    }

    static func combining(_ results: [RiskSampleResult]) -> RiskAggregate {
        var categories: [String: Int] = [:]
        for result in results {
            for (category, count) in result.falseWarningsByCategory {
                categories[category, default: 0] += count
            }
        }

        return RiskAggregate(
            sampleCount: results.count,
            criticalErrors: results.reduce(0) { $0 + $1.criticalErrors },
            criticalErrorsMarked: results.reduce(0) { $0 + $1.criticalErrorsMarked },
            criticalWordsDropped: results.reduce(0) { $0 + $1.criticalWordsDropped },
            wordCount: results.reduce(0) { $0 + $1.wordCount },
            correctWordCount: results.reduce(0) { $0 + $1.correctWordCount },
            falseWarnings: results.reduce(0) { $0 + $1.falseWarnings },
            falseWarningsByCategory: categories,
            unexplainedCleanupChanges: results.reduce(0) { $0 + $1.unexplainedCleanupChanges },
            reviewedSampleCount: results.filter(\.requiresReview).count
        )
    }
}

struct RiskReport: Sendable, Equatable {
    let title: String
    let engineIdentifier: String
    let corpusName: String
    let machine: String
    let weights: RiskWeights
    let policy: ReviewPolicy
    let results: [RiskSampleResult]
    let overall: RiskAggregate
    let byLanguage: [SpeechLanguage: RiskAggregate]
    let failures: [String]
}

/// Measures what the risk engine does, on the same corpus Phase 2 scored.
///
/// It extends the Phase 2 harness instead of inventing a second one, so recall
/// and word error rate are computed from the same corpus, the same
/// normalization, and the same alignment. Two harnesses would eventually
/// disagree, and the disagreement would be invisible.
///
/// The two measurements have different requirements, on purpose:
///
/// - **False-warning density and semantic preservation** need no engine at all.
///   Running the signals over the reference sentences answers "how often does
///   this mark text that is already correct", which is the question, and
///   answers it deterministically.
/// - **Recall** needs real errors, so it needs a real engine over real audio.
enum RiskBenchmark {
    /// Scores the risk engine on text that is already correct.
    ///
    /// Every mark here is by definition a false warning: the hypothesis *is*
    /// the reference. This is the model-free half of the measurement.
    static func runOnReferences(
        corpus: BenchmarkCorpus,
        engine: RiskEngine = .standard(),
        cleanup: any CleanupService = ConservativeCleanupService(),
        policy: ReviewPolicy = .default,
        glossary: [GlossaryEntry] = [],
        normalizer: TextNormalizer = .default,
        machine: String = BenchmarkRunner.machineDescription()
    ) -> RiskReport {
        let results = corpus.samples.map { sample in
            score(
                sample: sample,
                hypothesis: sample.reference,
                tokens: [],
                engine: engine,
                cleanup: cleanup,
                policy: policy,
                glossary: glossary,
                normalizer: normalizer
            )
        }

        return report(
            title: "Risk engine on correct text (no speech engine)",
            engineIdentifier: "reference",
            corpus: corpus,
            machine: machine,
            engine: engine,
            policy: policy,
            results: results,
            failures: []
        )
    }

    /// Scores the risk engine on what a speech engine actually produced.
    static func run(
        engine speechEngine: any TranscriptionService,
        corpus: BenchmarkCorpus,
        directory: URL,
        riskEngine: RiskEngine = .standard(),
        cleanup: any CleanupService = ConservativeCleanupService(),
        policy: ReviewPolicy = .default,
        glossary: [GlossaryEntry] = [],
        normalizer: TextNormalizer = .default,
        machine: String = BenchmarkRunner.machineDescription()
    ) async -> RiskReport {
        var results: [RiskSampleResult] = []
        var failures: [String] = []
        var prepared: Set<LanguageProfile> = []
        var preparationFailures: [LanguageProfile: String] = [:]

        for sample in corpus.samples {
            let profile = sample.languageProfile
            guard speechEngine.supports(profile) else {
                failures.append("\(sample.audio): \(profile.displayName) unsupported by \(speechEngine.identifier)")
                continue
            }
            if let failure = preparationFailures[profile] {
                failures.append("\(sample.audio): \(failure)")
                continue
            }
            if !prepared.contains(profile) {
                do {
                    try await speechEngine.prepare(for: profile)
                    prepared.insert(profile)
                } catch {
                    let message = (error as? TranscriptionError)?.message ?? error.localizedDescription
                    preparationFailures[profile] = message
                    failures.append("\(sample.audio): \(message)")
                    continue
                }
            }

            do {
                let utterance = try corpus.utterance(for: sample, in: directory)
                let transcript = try await speechEngine.transcribe(utterance, profile: profile)
                results.append(
                    score(
                        sample: sample,
                        hypothesis: transcript.text,
                        tokens: transcript.tokens,
                        engine: riskEngine,
                        cleanup: cleanup,
                        policy: policy,
                        glossary: glossary,
                        normalizer: normalizer
                    )
                )
            } catch {
                let message = (error as? TranscriptionError)?.message
                    ?? (error as? BenchmarkCorpusError)?.message
                    ?? error.localizedDescription
                failures.append("\(sample.audio): \(message)")
            }
        }

        return report(
            title: "Risk engine on \(speechEngine.displayName) output",
            engineIdentifier: speechEngine.identifier,
            corpus: corpus,
            machine: machine,
            engine: riskEngine,
            policy: policy,
            results: results,
            failures: failures
        )
    }

    // MARK: - Scoring


    /// The same word-in-its-neighbourhood question the risk engine asks, so the
    /// definition that scores a corpus and the definition that marks a
    /// transcript stay the one definition Phase 3 promoted them into being.
    private static func isCritical(_ words: [String], at index: Int) -> Bool {
        guard words.indices.contains(index) else { return false }
        let window = CriticalTokens.dateContextWindow
        return CriticalTokens.isCritical(
            words[index],
            precededBy: Array(words[max(index - window, 0)..<index]),
            followedBy: Array(words[(index + 1)..<min(index + 1 + window, words.count)])
        )
    }

    static func score(
        sample: BenchmarkSample,
        hypothesis: String,
        tokens: [TranscriptToken],
        engine: RiskEngine,
        cleanup: any CleanupService,
        policy: ReviewPolicy,
        glossary: [GlossaryEntry],
        normalizer: TextNormalizer = .default
    ) -> RiskSampleResult {
        let language = sample.language
        let profile = sample.languageProfile

        let cleanupResult = cleanup.clean(hypothesis, language: language)
        let spans = engine.analyze(
            cleanup: cleanupResult,
            tokens: tokens,
            profile: profile,
            glossary: glossary
        )
        let decision = ReviewCoordinator.decide(
            spans: spans,
            policy: policy,
            isEmptyResult: cleanupResult.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        let flagged = decision.flaggedSpans

        // Positions are needed, so the hypothesis is scanned rather than
        // normalized wholesale: normalization deliberately destroys offsets and
        // a span has to be attributable to a specific word.
        let hypothesisWords: [ScoredWord] = WordScanner.words(in: hypothesis).compactMap { word in
            let normalized = normalizer.normalize(word.text, language: language)
            guard !normalized.isEmpty else { return nil }
            return ScoredWord(normalized: normalized, range: word.range)
        }
        let referenceWords = normalizer.words(sample.reference, language: language)

        let operations = TranscriptionScorer.align(
            reference: referenceWords,
            hypothesis: hypothesisWords.map(\.normalized)
        )

        var criticalErrors = 0
        var criticalErrorsMarked = 0
        var criticalWordsDropped = 0
        var correctWordCount = 0
        var incorrectRanges: [Range<Int>] = []

        func isMarked(_ range: Range<Int>) -> Bool {
            flagged.contains { $0.rawRange.overlaps(range) }
        }

        for operation in operations {
            switch operation {
            case .match:
                correctWordCount += 1

            case let .substitution(reference: referenceIndex, hypothesis: hypothesisIndex):
                guard hypothesisIndex < hypothesisWords.count else { break }
                let range = hypothesisWords[hypothesisIndex].range
                incorrectRanges.append(range)
                let isCritical = Self.isCritical(referenceWords, at: referenceIndex)
                    || Self.isCritical(hypothesisWords.map(\.normalized), at: hypothesisIndex)
                if isCritical {
                    criticalErrors += 1
                    if isMarked(range) { criticalErrorsMarked += 1 }
                }

            case let .insertion(hypothesis: hypothesisIndex):
                guard hypothesisIndex < hypothesisWords.count else { break }
                let range = hypothesisWords[hypothesisIndex].range
                incorrectRanges.append(range)
                if Self.isCritical(hypothesisWords.map(\.normalized), at: hypothesisIndex) {
                    criticalErrors += 1
                    if isMarked(range) { criticalErrorsMarked += 1 }
                }

            case let .deletion(reference: referenceIndex):
                // The word is simply not in the text. This is the class
                // `docs/PHASE_3.md` decided not to chase: no rule can flag what
                // is absent, and it is counted here so the decision stays
                // visible in the numbers rather than becoming invisible.
                if Self.isCritical(referenceWords, at: referenceIndex) {
                    criticalWordsDropped += 1
                }
            }
        }

        var falseWarnings = 0
        var falseWarningsByCategory: [String: Int] = [:]
        for span in flagged {
            let touchesAnError = incorrectRanges.contains { $0.overlaps(span.rawRange) }
            guard !touchesAnError else { continue }
            falseWarnings += 1
            falseWarningsByCategory[span.reason.category, default: 0] += 1
        }

        return RiskSampleResult(
            audio: sample.audio,
            language: language,
            profile: profile,
            reference: sample.reference,
            hypothesis: hypothesis,
            cleaned: cleanupResult.cleaned,
            criticalErrors: criticalErrors,
            criticalErrorsMarked: criticalErrorsMarked,
            criticalWordsDropped: criticalWordsDropped,
            wordCount: hypothesisWords.count,
            correctWordCount: correctWordCount,
            falseWarnings: falseWarnings,
            falseWarningsByCategory: falseWarningsByCategory,
            unexplainedCleanupChanges: unexplainedChanges(in: cleanupResult, normalizer: normalizer),
            editKinds: cleanupResult.edits.map { $0.kind.rawValue }.sorted(),
            requiresReview: decision.requiresReview
        )
    }

    /// Differences between the raw and cleaned word sequences that filler
    /// removal does not account for.
    ///
    /// Cleanup is allowed to delete a listed filler and nothing else. Anything
    /// this returns above zero is cleanup changing what the user said, which
    /// is the failure `docs/PHASE_3.md` calls semantic preservation.
    static func unexplainedChanges(
        in cleanup: CleanupResult,
        normalizer: TextNormalizer = .default
    ) -> Int {
        let language = cleanup.language
        let rawWords = normalizer.words(cleanup.raw, language: language)
        let cleanedWords = normalizer.words(cleanup.cleaned, language: language)
        let removed = cleanup.wordRemovingEdits.map {
            normalizer.normalize($0.rawText, language: language).trimmingCharacters(in: .whitespaces)
        }

        var allowedDeletions: [String: Int] = [:]
        for word in removed where !word.isEmpty {
            allowedDeletions[word, default: 0] += 1
        }

        let operations = TranscriptionScorer.align(reference: rawWords, hypothesis: cleanedWords)
        var unexplained = 0

        for operation in operations {
            switch operation {
            case .match:
                break
            case let .deletion(reference: index):
                let word = rawWords[index]
                if let remaining = allowedDeletions[word], remaining > 0 {
                    allowedDeletions[word] = remaining - 1
                } else {
                    unexplained += 1
                }
            case .substitution, .insertion:
                unexplained += 1
            }
        }

        return unexplained
    }

    private static func report(
        title: String,
        engineIdentifier: String,
        corpus: BenchmarkCorpus,
        machine: String,
        engine: RiskEngine,
        policy: ReviewPolicy,
        results: [RiskSampleResult],
        failures: [String]
    ) -> RiskReport {
        var byLanguage: [SpeechLanguage: RiskAggregate] = [:]
        for language in SpeechLanguage.allCases {
            let subset = results.filter { $0.language == language }
            guard !subset.isEmpty else { continue }
            byLanguage[language] = .combining(subset)
        }

        return RiskReport(
            title: title,
            engineIdentifier: engineIdentifier,
            corpusName: corpus.name,
            machine: machine,
            weights: engine.weights,
            policy: policy,
            results: results,
            overall: .combining(results),
            byLanguage: byLanguage,
            failures: failures
        )
    }
}

extension RiskReport {
    /// Markdown for `docs/PHASE_3_MEASUREMENT.md`.
    func markdown() -> String {
        func percent(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1f%%", value * 100)
        }
        func density(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1f", value)
        }

        var lines: [String] = []
        lines.append("## \(title)")
        lines.append("")
        lines.append("Corpus: \(corpusName) · \(overall.sampleCount) samples · \(machine)")
        lines.append("")
        lines.append("Flag threshold \(String(format: "%.2f", policy.flagThreshold)) · model-confidence weight \(String(format: "%.2f", weights.modelConfidence))")
        lines.append("")
        lines.append("| Language | Samples | Critical errors | Recall | Dropped (unmarkable) | False warnings / 100 words | Semantic preservation | Review shown |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

        for language in SpeechLanguage.allCases {
            guard let aggregate = byLanguage[language] else { continue }
            lines.append(
                "| \(language.displayName) | \(aggregate.sampleCount) | \(aggregate.criticalErrors) | "
                + "\(percent(aggregate.recall)) | \(aggregate.criticalWordsDropped) | "
                + "\(density(aggregate.falseWarningDensity)) | \(percent(aggregate.semanticPreservation)) | "
                + "\(percent(aggregate.reviewRate)) |"
            )
        }

        lines.append(
            "| **Overall** | \(overall.sampleCount) | \(overall.criticalErrors) | "
            + "\(percent(overall.recall)) | \(overall.criticalWordsDropped) | "
            + "\(density(overall.falseWarningDensity)) | \(percent(overall.semanticPreservation)) | "
            + "\(percent(overall.reviewRate)) |"
        )

        if !overall.falseWarningsByCategory.isEmpty {
            lines.append("")
            lines.append("### False warnings by signal")
            lines.append("")
            lines.append("| Signal | Marks on correct text |")
            lines.append("| --- | ---: |")
            for (category, count) in overall.falseWarningsByCategory.sorted(by: { $0.value > $1.value }) {
                lines.append("| \(category) | \(count) |")
            }
        }

        let changed = results.filter { $0.unexplainedCleanupChanges > 0 }
        if !changed.isEmpty {
            lines.append("")
            lines.append("### Cleanup changed more than punctuation")
            lines.append("")
            for result in changed {
                lines.append("- **\(result.audio)** — \(result.unexplainedCleanupChanges) unexplained word changes")
                lines.append("  - raw: `\(result.hypothesis)`")
                lines.append("  - cleaned: `\(result.cleaned)`")
            }
        }

        let missed = results.filter { $0.criticalErrors > $0.criticalErrorsMarked }
        if !missed.isEmpty {
            lines.append("")
            lines.append("### Critical errors the engine did not mark")
            lines.append("")
            for result in missed {
                lines.append("- **\(result.audio)** — \(result.criticalErrorsMarked)/\(result.criticalErrors) marked")
                lines.append("  - ref: `\(result.reference)`")
                lines.append("  - hyp: `\(result.hypothesis)`")
            }
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("### Failures")
            lines.append("")
            for failure in failures {
                lines.append("- \(failure)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
#endif
