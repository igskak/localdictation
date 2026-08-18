#if DEBUG
import Foundation

/// Scores for one corpus sample.
struct BenchmarkSampleResult: Sendable, Equatable {
    let audio: String
    let language: SpeechLanguage
    let profile: LanguageProfile
    let word: ErrorRate
    let character: ErrorRate
    let numeric: ErrorRate
    let calibration: ConfidenceCalibration
    let audioDuration: TimeInterval
    let processingDuration: TimeInterval
    let hasConfidenceSignal: Bool

    var realTimeFactor: Double? {
        audioDuration > 0 ? processingDuration / audioDuration : nil
    }
}

/// Aggregate over a set of samples — one language, or the whole corpus.
struct BenchmarkAggregate: Sendable, Equatable {
    let sampleCount: Int
    let word: ErrorRate
    let character: ErrorRate
    let numeric: ErrorRate
    let audioDuration: TimeInterval
    let processingDuration: TimeInterval
    /// Pooled over every scored token, so long samples do not count twice.
    let correctTokenCount: Int
    let incorrectTokenCount: Int
    let meanConfidenceWhenCorrect: Double?
    let meanConfidenceWhenIncorrect: Double?
    let flaggedIncorrect: Int
    let flaggedCorrect: Int
    let confidenceThreshold: Double
    let samplesWithConfidence: Int

    var realTimeFactor: Double? {
        audioDuration > 0 ? processingDuration / audioDuration : nil
    }

    /// Positive means low confidence really does track mistakes.
    var confidenceSeparation: Double? {
        guard let correct = meanConfidenceWhenCorrect,
              let incorrect = meanConfidenceWhenIncorrect
        else { return nil }
        return correct - incorrect
    }

    var riskRecall: Double? {
        incorrectTokenCount > 0 ? Double(flaggedIncorrect) / Double(incorrectTokenCount) : nil
    }

    var falseWarningRate: Double? {
        correctTokenCount > 0 ? Double(flaggedCorrect) / Double(correctTokenCount) : nil
    }

    static func combining(_ results: [BenchmarkSampleResult], threshold: Double) -> BenchmarkAggregate {
        var word = ErrorRate.zero
        var character = ErrorRate.zero
        var numeric = ErrorRate.zero
        var audio: TimeInterval = 0
        var processing: TimeInterval = 0
        var correct = 0
        var incorrect = 0
        var correctConfidenceSum = 0.0
        var correctConfidenceCount = 0
        var incorrectConfidenceSum = 0.0
        var incorrectConfidenceCount = 0
        var flaggedIncorrect = 0
        var flaggedCorrect = 0
        var withConfidence = 0

        for result in results {
            word = word + result.word
            character = character + result.character
            numeric = numeric + result.numeric
            audio += result.audioDuration
            processing += result.processingDuration

            let calibration = result.calibration
            correct += calibration.correctCount
            incorrect += calibration.incorrectCount

            if let mean = calibration.meanConfidenceWhenCorrect {
                correctConfidenceSum += mean * Double(calibration.correctCount)
                correctConfidenceCount += calibration.correctCount
            }
            if let mean = calibration.meanConfidenceWhenIncorrect {
                incorrectConfidenceSum += mean * Double(calibration.incorrectCount)
                incorrectConfidenceCount += calibration.incorrectCount
            }
            if let recall = calibration.recall {
                flaggedIncorrect += Int((recall * Double(calibration.incorrectCount)).rounded())
            }
            if let rate = calibration.falseWarningRate {
                flaggedCorrect += Int((rate * Double(calibration.correctCount)).rounded())
            }
            if result.hasConfidenceSignal { withConfidence += 1 }
        }

        return BenchmarkAggregate(
            sampleCount: results.count,
            word: word,
            character: character,
            numeric: numeric,
            audioDuration: audio,
            processingDuration: processing,
            correctTokenCount: correct,
            incorrectTokenCount: incorrect,
            meanConfidenceWhenCorrect: correctConfidenceCount > 0
                ? correctConfidenceSum / Double(correctConfidenceCount) : nil,
            meanConfidenceWhenIncorrect: incorrectConfidenceCount > 0
                ? incorrectConfidenceSum / Double(incorrectConfidenceCount) : nil,
            flaggedIncorrect: flaggedIncorrect,
            flaggedCorrect: flaggedCorrect,
            confidenceThreshold: threshold,
            samplesWithConfidence: withConfidence
        )
    }
}

struct BenchmarkReport: Sendable, Equatable {
    let engineIdentifier: String
    let engineName: String
    let corpusName: String
    let machine: String
    let results: [BenchmarkSampleResult]
    let overall: BenchmarkAggregate
    let byLanguage: [SpeechLanguage: BenchmarkAggregate]
    let failures: [String]
}

/// Runs one engine over a corpus and aggregates the scores.
///
/// It measures; it does not decide. The engine choice is made by reading the
/// report, not by anything in this file.
enum BenchmarkRunner {
    static func run(
        engine: any TranscriptionService,
        corpus: BenchmarkCorpus,
        directory: URL,
        machine: String = BenchmarkRunner.machineDescription(),
        confidenceThreshold: Double = 0.5,
        normalizer: TextNormalizer = .default
    ) async -> BenchmarkReport {
        var results: [BenchmarkSampleResult] = []
        var failures: [String] = []
        var prepared: Set<LanguageProfile> = []
        var preparationFailures: [LanguageProfile: String] = [:]

        for sample in corpus.samples {
            let profile = sample.languageProfile
            guard engine.supports(profile) else {
                failures.append("\(sample.audio): \(profile.displayName) unsupported by \(engine.identifier)")
                continue
            }

            // Preparation happens per profile, inside the run. An engine that
            // cannot serve one language must not abort the whole benchmark:
            // "no on-device German model" is a result worth recording, not a
            // reason to stop measuring the other three languages.
            if let failure = preparationFailures[profile] {
                failures.append("\(sample.audio): \(failure)")
                continue
            }
            if !prepared.contains(profile) {
                do {
                    try await engine.prepare(for: profile)
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
                let transcript = try await engine.transcribe(utterance, profile: profile)
                results.append(
                    score(
                        transcript: transcript,
                        sample: sample,
                        utteranceDuration: utterance.duration,
                        threshold: confidenceThreshold,
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

        var byLanguage: [SpeechLanguage: BenchmarkAggregate] = [:]
        for language in SpeechLanguage.allCases {
            let subset = results.filter { $0.language == language }
            guard !subset.isEmpty else { continue }
            byLanguage[language] = .combining(subset, threshold: confidenceThreshold)
        }

        return BenchmarkReport(
            engineIdentifier: engine.identifier,
            engineName: engine.displayName,
            corpusName: corpus.name,
            machine: machine,
            results: results,
            overall: .combining(results, threshold: confidenceThreshold),
            byLanguage: byLanguage,
            failures: failures
        )
    }

    static func score(
        transcript: Transcript,
        sample: BenchmarkSample,
        utteranceDuration: TimeInterval,
        threshold: Double,
        normalizer: TextNormalizer = .default
    ) -> BenchmarkSampleResult {
        let language = sample.language
        return BenchmarkSampleResult(
            audio: sample.audio,
            language: language,
            profile: sample.languageProfile,
            word: TranscriptionScorer.wordErrorRate(
                reference: sample.reference,
                hypothesis: transcript.text,
                language: language,
                normalizer: normalizer
            ),
            character: TranscriptionScorer.characterErrorRate(
                reference: sample.reference,
                hypothesis: transcript.text,
                language: language,
                normalizer: normalizer
            ),
            numeric: TranscriptionScorer.errorRate(
                reference: sample.reference,
                hypothesis: transcript.text,
                language: language,
                normalizer: normalizer,
                selecting: CriticalTokens.isNumeric
            ),
            calibration: TranscriptionScorer.calibration(
                of: transcript,
                reference: sample.reference,
                language: language,
                threshold: threshold,
                normalizer: normalizer
            ),
            audioDuration: utteranceDuration,
            processingDuration: transcript.processingDuration,
            hasConfidenceSignal: transcript.hasConfidenceSignal
        )
    }

    static func machineDescription() -> String {
        let info = ProcessInfo.processInfo
        return "macOS \(info.operatingSystemVersionString), \(info.processorCount) cores"
    }
}

extension BenchmarkReport {
    /// Markdown for `docs/PHASE_2_BENCHMARK.md`.
    func markdown() -> String {
        func percent(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1f%%", value * 100)
        }
        func number(_ value: Double?, _ format: String = "%.2f") -> String {
            guard let value else { return "n/a" }
            return String(format: format, value)
        }

        var lines: [String] = []
        lines.append("## \(engineName) (`\(engineIdentifier)`)")
        lines.append("")
        lines.append("Corpus: \(corpusName) · \(overall.sampleCount) samples · \(machine)")
        lines.append("")
        lines.append("| Language | Samples | WER | CER | Numeric ER | RTF | Confidence separation | Risk recall @ \(number(overall.confidenceThreshold)) | False warnings |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

        for language in SpeechLanguage.allCases {
            guard let aggregate = byLanguage[language] else { continue }
            lines.append(
                "| \(language.displayName) | \(aggregate.sampleCount) | \(percent(aggregate.word.rate)) | "
                + "\(percent(aggregate.character.rate)) | \(percent(aggregate.numeric.rate)) | "
                + "\(number(aggregate.realTimeFactor)) | \(number(aggregate.confidenceSeparation, "%.3f")) | "
                + "\(percent(aggregate.riskRecall)) | \(percent(aggregate.falseWarningRate)) |"
            )
        }

        lines.append(
            "| **Overall** | \(overall.sampleCount) | \(percent(overall.word.rate)) | "
            + "\(percent(overall.character.rate)) | \(percent(overall.numeric.rate)) | "
            + "\(number(overall.realTimeFactor)) | \(number(overall.confidenceSeparation, "%.3f")) | "
            + "\(percent(overall.riskRecall)) | \(percent(overall.falseWarningRate)) |"
        )

        lines.append("")
        lines.append("Samples with any confidence signal: \(overall.samplesWithConfidence)/\(overall.sampleCount).")

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
