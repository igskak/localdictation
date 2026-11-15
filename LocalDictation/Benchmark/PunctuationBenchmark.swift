#if DEBUG
import Foundation

/// One sample scored twice: as Whisper wrote it, and as the app would insert
/// it after Conservative cleanup. The two differ only by what our own rules
/// add, which is how the report separates the engine's punctuation mistakes
/// from ours.
struct PunctuationSampleResult: Sendable, Equatable {
    let audio: String
    let language: SpeechLanguage
    let kind: String?
    let reference: String
    let engineText: String
    let insertedText: String
    let word: ErrorRate
    let engine: PunctuationScore
    let inserted: PunctuationScore
    let audioDuration: TimeInterval
    let processingDuration: TimeInterval

    /// Whisper ended the utterance on a letter or digit, so the final mark,
    /// if any, is ours.
    var engineLeftEndOpen: Bool {
        PunctuationScorer.finalMark(engineText, language: language) == .unmarked
    }
}

struct PunctuationReport: Sendable {
    let variant: String
    let corpusName: String
    let machine: String
    let results: [PunctuationSampleResult]
    let failures: [String]

    var languages: [SpeechLanguage] { Set(results.map(\.language)).sorted() }
    var kinds: [String] { Set(results.compactMap(\.kind)).sorted() }
}

/// Measures punctuation and paragraphs on a corpus whose references are
/// punctuated the way the dictation should read.
///
/// It measures; it does not decide. Which engine, model, or prompt ships is
/// decided by reading the report.
enum PunctuationBenchmark {
    /// Style prompts for the Whisper prompt experiment: a statement, a yes/no
    /// question with no question word, and a comma, in each language. The
    /// content shares no sentence with the corpus scripts, so a prompt cannot
    /// win by echoing a reference.
    static let stylePrompts: [SpeechLanguage: String] = [
        .russian: "Добрый вечер. Вы уже на месте? Да, я подъеду минут через десять.",
        .ukrainian: "Добрий вечір. Ви вже на місці? Так, я під'їду хвилин за десять.",
        .german: "Guten Abend. Sind Sie schon da? Ja, ich bin in zehn Minuten dort.",
        .english: "Good evening. Are you there already? Yes, I will be there in ten minutes.",
    ]

    static func run(
        engine: any TranscriptionService,
        variant: String,
        corpus: BenchmarkCorpus,
        directory: URL,
        cleanup: any CleanupService = AdaptiveCleanupService(),
        normalizer: TextNormalizer = .default
    ) async -> PunctuationReport {
        var results: [PunctuationSampleResult] = []
        var failures: [String] = []
        var prepared: Set<LanguageProfile> = []

        for sample in corpus.samples {
            let profile = sample.languageProfile
            do {
                if !prepared.contains(profile) {
                    try await engine.prepare(for: profile)
                    prepared.insert(profile)
                }
                let utterance = try corpus.utterance(for: sample, in: directory)
                let transcript = try await engine.transcribe(utterance, profile: profile)
                results.append(score(
                    transcript: transcript,
                    sample: sample,
                    audioDuration: utterance.duration,
                    cleanup: cleanup,
                    normalizer: normalizer
                ))
            } catch {
                let message = (error as? TranscriptionError)?.message
                    ?? (error as? BenchmarkCorpusError)?.message
                    ?? error.localizedDescription
                failures.append("\(sample.audio): \(message)")
            }
        }

        return PunctuationReport(
            variant: variant,
            corpusName: corpus.name,
            machine: BenchmarkRunner.machineDescription(),
            results: results,
            failures: failures
        )
    }

    static func score(
        transcript: Transcript,
        sample: BenchmarkSample,
        audioDuration: TimeInterval,
        cleanup: any CleanupService = AdaptiveCleanupService(),
        normalizer: TextNormalizer = .default
    ) -> PunctuationSampleResult {
        let language = sample.language
        // The language the app would clean as: the decoded one when it is in
        // the profile, the profile's first otherwise.
        let cleanupLanguage = transcript.detectedLanguage.flatMap {
            transcript.profile.contains($0) ? $0 : nil
        } ?? transcript.profile.primary
        // Conservative is the fresh-install default and what users have today.
        let inserted = cleanup.clean(
            transcript.text,
            language: cleanupLanguage,
            options: CleanupOptions(
                level: .conservative,
                timing: CleanupTimingEvidence.validated(transcript: transcript)
            )
        ).cleaned

        return PunctuationSampleResult(
            audio: sample.audio,
            language: language,
            kind: sample.kind,
            reference: sample.reference,
            engineText: transcript.text,
            insertedText: inserted,
            word: TranscriptionScorer.wordErrorRate(
                reference: sample.reference,
                hypothesis: transcript.text,
                language: language,
                normalizer: normalizer
            ),
            engine: PunctuationScorer.score(
                reference: sample.reference,
                hypothesis: transcript.text,
                language: language,
                normalizer: normalizer
            ),
            inserted: PunctuationScorer.score(
                reference: sample.reference,
                hypothesis: inserted,
                language: language,
                normalizer: normalizer
            ),
            audioDuration: audioDuration,
            processingDuration: transcript.processingDuration
        )
    }
}

extension PunctuationReport {
    func markdown() -> String {
        func percent(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.0f%%", value * 100)
        }
        func pooled(_ subset: [PunctuationSampleResult], _ stage: KeyPath<PunctuationSampleResult, PunctuationScore>) -> PunctuationScore {
            subset.reduce(.zero) { $0 + $1[keyPath: stage] }
        }

        var lines: [String] = []
        lines.append("## \(variant)")
        lines.append("")
        lines.append("Corpus: \(corpusName) · \(results.count) samples · \(machine)")
        lines.append("")
        lines.append("Two rows per language: **engine** is Whisper's text, **inserted** is what the app inserts after Conservative cleanup. `?→.` counts questions written as statements; `open end` is the share of samples Whisper ended without any mark.")
        lines.append("")
        lines.append("| Language | Stage | Samples | WER | `?` recall | `?` precision | `?→.` | `.` F1 | `,` F1 | Sentence F1 | ¶ recall | ¶ precision | Open end | RTF |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

        let rows: [(String, [PunctuationSampleResult])] =
            languages.map { language in (language.displayName, results.filter { $0.language == language }) }
            + [("**All**", results)]
        for (label, subset) in rows where !subset.isEmpty {
            let word = subset.reduce(ErrorRate.zero) { $0 + $1.word }
            let audio = subset.reduce(0) { $0 + $1.audioDuration }
            let processing = subset.reduce(0) { $0 + $1.processingDuration }
            let open = Double(subset.filter(\.engineLeftEndOpen).count) / Double(subset.count)
            for (stage, path) in [("engine", \PunctuationSampleResult.engine), ("inserted", \PunctuationSampleResult.inserted)] {
                let score = pooled(subset, path)
                let isEngine = stage == "engine"
                lines.append(
                    "| \(label) | \(stage) | \(subset.count) | \(isEngine ? percent(word.rate) : "") | "
                    + "\(percent(score.recall(.question))) | \(percent(score.precision(.question))) | "
                    + "\(score.count(reference: .question, hypothesis: .period))/\(score.support(.question)) | "
                    + "\(percent(score.f1(.period))) | \(percent(score.f1(.comma))) | "
                    + "\(percent(score.sentenceBoundaryF1)) | \(percent(score.paragraphRecall)) | "
                    + "\(percent(score.paragraphPrecision)) | \(isEngine ? percent(open) : "") | "
                    + "\(isEngine && audio > 0 ? String(format: "%.2f", processing / audio) : "") |"
                )
            }
        }

        if !kinds.isEmpty {
            lines.append("")
            lines.append("### Question recall by sentence kind (inserted text)")
            lines.append("")
            lines.append("| Kind | " + languages.map(\.displayName).joined(separator: " | ") + " |")
            lines.append("| --- |" + languages.map { _ in " ---: |" }.joined())
            for kind in kinds {
                let cells = languages.map { language -> String in
                    let subset = results.filter { $0.language == language && $0.kind == kind }
                    let score = pooled(subset, \.inserted)
                    guard score.support(.question) > 0 else { return "" }
                    return "\(score.count(reference: .question, hypothesis: .question))/\(score.support(.question))"
                }
                guard cells.contains(where: { !$0.isEmpty }) else { continue }
                lines.append("| \(kind) | " + cells.joined(separator: " | ") + " |")
            }
        }

        // A question missed, or a question mark where the reference has none.
        let misses = results.filter { result in
            let hits = result.inserted.count(reference: .question, hypothesis: .question)
            return result.inserted.support(.question) > hits
                || result.inserted.count(hypothesis: .question) > hits
        }
        if !misses.isEmpty {
            lines.append("")
            lines.append("### Question mistakes")
            lines.append("")
            for result in misses {
                lines.append("- **\(result.audio)** (\(result.kind ?? "no kind"))")
                lines.append("  - ref: `\(Self.oneLine(result.reference))`")
                lines.append("  - engine: `\(Self.oneLine(result.engineText))`")
                if result.insertedText != result.engineText {
                    lines.append("  - inserted: `\(Self.oneLine(result.insertedText))`")
                }
            }
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("### Failures")
            lines.append("")
            for failure in failures { lines.append("- \(failure)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Paragraph breaks shown as `¶`, so a sample stays on one Markdown line.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n\n", with: " ¶ ").replacingOccurrences(of: "\n", with: " ¶ ")
    }
}
#endif
