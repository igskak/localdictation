import XCTest
@testable import LocalDictation

/// The measurement harness, exercised without a corpus and without a model, so
/// the numbers it produces can be trusted before they are produced.
final class RiskBenchmarkTests: XCTestCase {
    private func sample(
        _ audio: String,
        reference: String,
        language: SpeechLanguage
    ) -> BenchmarkSample {
        BenchmarkSample(audio: audio, reference: reference, language: language, profile: nil)
    }

    private func score(
        reference: String,
        hypothesis: String,
        language: SpeechLanguage,
        glossary: [GlossaryEntry] = []
    ) -> RiskSampleResult {
        RiskBenchmark.score(
            sample: sample("a.wav", reference: reference, language: language),
            hypothesis: hypothesis,
            tokens: Transcript.fixture(
                text: hypothesis,
                profile: LanguageProfile(primary: language, secondary: nil)
            ).tokens,
            engine: .standard(),
            cleanup: ConservativeCleanupService(),
            policy: .default,
            glossary: glossary
        )
    }

    // MARK: - Recall

    func testAWrongAmountCountsAsACriticalErrorAndIsMarked() {
        let result = score(
            reference: "bitte überweise 1450 euro",
            hypothesis: "bitte überweise 1415 euro",
            language: .german
        )

        XCTAssertEqual(result.criticalErrors, 1)
        XCTAssertEqual(result.criticalErrorsMarked, 1)
    }

    func testAWrongOrdinaryWordIsNotACriticalError() {
        let result = score(
            reference: "der termin ist offen",
            hypothesis: "der termin ist oben",
            language: .german
        )

        XCTAssertEqual(result.criticalErrors, 0)
    }

    /// A dropped word leaves nothing to mark. `docs/PHASE_3.md` decided not to
    /// chase this class, and the number is reported rather than buried.
    func testACriticalWordDroppedEntirelyIsCountedSeparately() {
        let result = score(
            reference: "bitte überweise 1450 euro",
            hypothesis: "bitte überweise euro",
            language: .german
        )

        XCTAssertEqual(result.criticalWordsDropped, 1)
        XCTAssertEqual(result.criticalErrors, 0, "an absent word is not a markable error")
    }

    // MARK: - False warnings

    func testAMarkOnCorrectTextCountsAsAFalseWarning() {
        let result = score(
            reference: "bitte überweise 1450 euro",
            hypothesis: "bitte überweise 1450 euro",
            language: .german
        )

        XCTAssertEqual(result.criticalErrors, 0)
        XCTAssertEqual(result.falseWarnings, 2, "the amount and the currency were both right and both marked")
        XCTAssertEqual(result.falseWarningsByCategory["number"], 1)
        XCTAssertEqual(result.falseWarningsByCategory["currency"], 1)
    }

    func testAMarkThatLandsOnARealErrorIsNotAFalseWarning() {
        let result = score(
            reference: "bitte überweise 1450 euro",
            hypothesis: "bitte überweise 1415 euro",
            language: .german
        )

        XCTAssertEqual(result.falseWarningsByCategory["number"], nil)
        XCTAssertEqual(result.falseWarningsByCategory["currency"], 1, "the currency was right and still marked")
    }

    func testTextWithNothingCriticalProducesNoMarks() {
        let result = score(
            reference: "der termin ist bestätigt",
            hypothesis: "der termin ist bestätigt",
            language: .german
        )

        XCTAssertEqual(result.falseWarnings, 0)
        XCTAssertFalse(result.deservesAttention)
    }

    // MARK: - Semantic preservation

    func testConservativeCleanupChangesNoWords() {
        for (text, language) in [
            ("bitte überweise 1450 euro bis freitag", SpeechLanguage.german),
            ("переведи 1450 евро мюллеру до пятницы", .russian),
            ("переказати 1450 євро мюллеру до п'ятниці", .ukrainian),
            ("please transfer 1450 euro to miller by friday", .english),
        ] {
            let cleanup = ConservativeCleanupService().clean(text, language: language)
            XCTAssertEqual(
                RiskBenchmark.unexplainedChanges(in: cleanup),
                0,
                "cleanup changed the words of \(language.rawValue)"
            )
        }
    }

    func testRemovingAFillerIsAnExplainedChange() {
        let cleanup = ConservativeCleanupService().clean("ähm der termin steht", language: .german)

        XCTAssertFalse(cleanup.wordRemovingEdits.isEmpty)
        XCTAssertEqual(RiskBenchmark.unexplainedChanges(in: cleanup), 0)
    }

    /// The measurement has to be able to fail, or it is not measuring anything.
    func testAnUnfaithfulCleanupIsCaught() {
        let unfaithful = CleanupResult(
            raw: "bitte überweise 1450 euro",
            cleaned: "Bitte überweise 1415 Euro.",
            edits: [],
            map: .identity(length: 25),
            language: .german
        )

        XCTAssertEqual(RiskBenchmark.unexplainedChanges(in: unfaithful), 1)
    }

    // MARK: - Aggregation

    func testAggregatePoolsCountsRatherThanAveragingRates() {
        let first = score(
            reference: "bitte überweise 1450 euro",
            hypothesis: "bitte überweise 1415 euro",
            language: .german
        )
        let second = score(
            reference: "die rechnung ist offen betrag 89 euro",
            hypothesis: "die rechnung ist offen betrag 89 euro",
            language: .german
        )

        let aggregate = RiskAggregate.combining([first, second])

        XCTAssertEqual(aggregate.sampleCount, 2)
        XCTAssertEqual(aggregate.criticalErrors, 1)
        XCTAssertEqual(try XCTUnwrap(aggregate.recall), 1, accuracy: 0.0001)
        XCTAssertEqual(aggregate.wordCount, first.wordCount + second.wordCount)
        XCTAssertEqual(try XCTUnwrap(aggregate.semanticPreservation), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(aggregate.falseWarningDensity), 0)
    }

    func testRecallOverZeroErrorsIsNotAMeasurement() {
        let clean = score(
            reference: "der termin ist bestätigt",
            hypothesis: "der termin ist bestätigt",
            language: .german
        )

        XCTAssertNil(RiskAggregate.combining([clean]).recall)
    }

    func testMarkdownReportsEveryLanguageAndTheWeights() {
        let results = SpeechLanguage.verified.map { language in
            score(reference: "eins zwei", hypothesis: "eins zwei", language: language)
        }
        let report = RiskReport(
            title: "test",
            engineIdentifier: "reference",
            corpusName: "smoke",
            machine: "test",
            weights: .default,
            policy: .default,
            results: results,
            overall: .combining(results),
            byLanguage: Dictionary(
                uniqueKeysWithValues: SpeechLanguage.verified.enumerated().map { ($1, RiskAggregate.combining([results[$0]])) }
            ),
            failures: ["de/1.wav: unsupported"]
        )

        let markdown = report.markdown()
        for language in SpeechLanguage.verified {
            XCTAssertTrue(markdown.contains("| \(language.displayName) |"))
        }
        XCTAssertTrue(markdown.contains("model-confidence weight 0.00"))
        XCTAssertTrue(markdown.contains("de/1.wav: unsupported"))
    }

    // MARK: - Corpus-gated measurement

    /// False-warning density and semantic preservation need no speech engine:
    /// running the signals over the reference sentences answers "how often does
    /// this mark text that is already correct", deterministically.
    ///
    /// Recall needs real errors, so it needs `BENCHMARK_ENGINE=whisperkit` and
    /// real audio. Both reports land next to the corpus.
    func testRunAgainstTheInstalledCorpusIfPresent() async throws {
        let directory = BenchmarkRunnerTests.corpusDirectory
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(BenchmarkCorpus.manifestName).path
        ) else {
            throw XCTSkip("""
                No corpus installed at \(directory.path).
                Generate a smoke corpus with: python3 Tools/make_smoke_corpus.py
                See docs/PHASE_3_MEASUREMENT.md.
                """)
        }

        let corpus = try BenchmarkCorpus.load(from: directory)
        let selection = ProcessInfo.processInfo.environment["BENCHMARK_ENGINE"]?.lowercased()

        let report: RiskReport
        switch selection {
        case "whisperkit":
            executionTimeAllowance = 3600
            report = await RiskBenchmark.run(
                engine: WhisperKitTranscriptionService(),
                corpus: corpus,
                directory: directory
            )
        case "apple":
            executionTimeAllowance = 1800
            report = await RiskBenchmark.run(
                engine: AppleSpeechTranscriptionService(),
                corpus: corpus,
                directory: directory
            )
        default:
            report = RiskBenchmark.runOnReferences(corpus: corpus)
        }

        let markdown = report.markdown()
        print("\n\(markdown)\n")
        try markdown.write(
            to: directory.appendingPathComponent("risk-\(report.engineIdentifier).md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            report.overall.sampleCount + report.failures.count,
            corpus.samples.count,
            "every sample must be either scored or reported as a failure"
        )
    }
}
