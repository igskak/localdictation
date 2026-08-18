import XCTest
@testable import LocalDictation

/// Scoring and aggregation are exercised without audio files, so the benchmark
/// machinery stays verifiable on a machine that has no corpus installed.
final class BenchmarkRunnerTests: XCTestCase {
    private func sample(
        _ audio: String,
        reference: String,
        language: SpeechLanguage = .english,
        profile: String? = nil
    ) -> BenchmarkSample {
        BenchmarkSample(audio: audio, reference: reference, language: language, profile: profile)
    }

    func testSampleScoringSeparatesOverallAndNumericErrors() {
        let transcript = Transcript.fixture(
            words: [("transfer", 0.95), ("1415", 0.2), ("euro", 0.9)],
            profile: .english,
            audioDuration: 2,
            processingDuration: 0.4
        )

        let result = BenchmarkRunner.score(
            transcript: transcript,
            sample: sample("a.wav", reference: "transfer 1450 euro"),
            utteranceDuration: 2,
            threshold: 0.5
        )

        XCTAssertEqual(try XCTUnwrap(result.word.rate), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.numeric.rate), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.realTimeFactor), 0.2, accuracy: 0.0001)
        XCTAssertTrue(result.hasConfidenceSignal)
        XCTAssertEqual(try XCTUnwrap(result.calibration.recall), 1.0, accuracy: 0.0001)
    }

    func testAggregatePoolsErrorsRatherThanAveragingRates() {
        // A 1-error-in-2-words sample and a 1-error-in-8-words sample pool to
        // 2/10, not to the 31% you would get by averaging the two rates.
        let short = BenchmarkRunner.score(
            transcript: .fixture(words: [("a", 0.9), ("x", 0.9)]),
            sample: sample("short.wav", reference: "a b"),
            utteranceDuration: 1,
            threshold: 0.5
        )
        let long = BenchmarkRunner.score(
            transcript: .fixture(
                words: [("c", 0.9), ("d", 0.9), ("e", 0.9), ("f", 0.9),
                        ("g", 0.9), ("h", 0.9), ("i", 0.9), ("z", 0.9)]
            ),
            sample: sample("long.wav", reference: "c d e f g h i j"),
            utteranceDuration: 4,
            threshold: 0.5
        )

        let aggregate = BenchmarkAggregate.combining([short, long], threshold: 0.5)

        XCTAssertEqual(aggregate.sampleCount, 2)
        XCTAssertEqual(aggregate.word.referenceCount, 10)
        XCTAssertEqual(aggregate.word.errors, 2)
        XCTAssertEqual(try XCTUnwrap(aggregate.word.rate), 0.2, accuracy: 0.0001)
    }

    func testAggregateRealTimeFactorUsesTotalDurations() {
        let first = BenchmarkRunner.score(
            transcript: .fixture(words: [("a", 0.9)], audioDuration: 10, processingDuration: 1),
            sample: sample("a.wav", reference: "a"),
            utteranceDuration: 10,
            threshold: 0.5
        )
        let second = BenchmarkRunner.score(
            transcript: .fixture(words: [("b", 0.9)], audioDuration: 10, processingDuration: 3),
            sample: sample("b.wav", reference: "b"),
            utteranceDuration: 10,
            threshold: 0.5
        )

        let aggregate = BenchmarkAggregate.combining([first, second], threshold: 0.5)
        XCTAssertEqual(try XCTUnwrap(aggregate.realTimeFactor), 0.2, accuracy: 0.0001)
    }

    /// An engine with no confidence signal has to be visible as such in the
    /// aggregate, because that alone disqualifies it for Phase 3.
    func testAggregateReportsMissingConfidenceSignal() {
        let result = BenchmarkRunner.score(
            transcript: .fixture(words: [("a", nil), ("b", nil)]),
            sample: sample("a.wav", reference: "a b"),
            utteranceDuration: 1,
            threshold: 0.5
        )

        let aggregate = BenchmarkAggregate.combining([result], threshold: 0.5)
        XCTAssertEqual(aggregate.samplesWithConfidence, 0)
        XCTAssertNil(aggregate.confidenceSeparation)
    }

    func testEmptyAggregateHasNoRates() {
        let aggregate = BenchmarkAggregate.combining([], threshold: 0.5)
        XCTAssertEqual(aggregate.sampleCount, 0)
        XCTAssertNil(aggregate.word.rate)
        XCTAssertNil(aggregate.realTimeFactor)
    }

    // MARK: - Corpus manifest

    func testManifestDecodesAndResolvesProfiles() throws {
        let json = """
        {
          "name": "smoke",
          "samples": [
            {"audio": "de/1.wav", "reference": "Rechnung über 1450 Euro", "language": "de", "profile": "de+en"},
            {"audio": "uk/1.wav", "reference": "Привіт", "language": "uk"}
          ]
        }
        """
        let corpus = try JSONDecoder().decode(BenchmarkCorpus.self, from: Data(json.utf8))

        XCTAssertEqual(corpus.samples.count, 2)
        XCTAssertEqual(corpus.samples[0].languageProfile, .germanEnglish)
        XCTAssertEqual(corpus.samples[1].languageProfile, .ukrainian, "a missing profile falls back to the language")
        XCTAssertEqual(corpus.languages, [.german, .ukrainian])
        XCTAssertEqual(corpus.samples(for: .german).count, 1)
    }

    func testLoadingReportsAMissingManifestClearly() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localdictation-absent-corpus-\(UUID().uuidString)")

        XCTAssertThrowsError(try BenchmarkCorpus.load(from: directory)) { error in
            guard case .manifestMissing = error as? BenchmarkCorpusError else {
                return XCTFail("Expected a manifestMissing error, got \(error)")
            }
        }
    }

    // MARK: - Report rendering

    func testMarkdownReportsPerLanguageRowsAndFailures() {
        let german = BenchmarkRunner.score(
            transcript: .fixture(words: [("Rechnung", 0.9)], profile: .german),
            sample: sample("de/1.wav", reference: "Rechnung", language: .german),
            utteranceDuration: 1,
            threshold: 0.5
        )
        let report = BenchmarkReport(
            engineIdentifier: "fake",
            engineName: "Fake Engine",
            corpusName: "smoke",
            machine: "test",
            results: [german],
            overall: .combining([german], threshold: 0.5),
            byLanguage: [.german: .combining([german], threshold: 0.5)],
            failures: ["uk/1.wav: unsupported"]
        )

        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("Fake Engine"))
        XCTAssertTrue(markdown.contains("| German |"))
        XCTAssertTrue(markdown.contains("**Overall**"))
        XCTAssertTrue(markdown.contains("uk/1.wav: unsupported"))
    }

    // MARK: - Corpus-gated integration

    /// Runs only when a corpus is present in the git-ignored `/Benchmark/`
    /// directory, so the suite stays green on a machine without speech data.
    ///
    /// Engine selection comes from the `BENCHMARK_ENGINE` environment variable:
    ///
    /// - unset — a fake engine, which checks the harness in a second;
    /// - `apple` — on-device `SFSpeechRecognizer`;
    /// - `whisperkit` — Whisper, downloading roughly 600 MB on first run.
    ///
    /// The rendered report is written next to the corpus for pasting into
    /// `docs/PHASE_2_BENCHMARK.md`.
    func testRunAgainstTheInstalledCorpusIfPresent() async throws {
        let directory = Self.corpusDirectory
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(BenchmarkCorpus.manifestName).path
        ) else {
            throw XCTSkip("""
                No corpus installed at \(directory.path).
                Generate a smoke corpus with: python3 Tools/make_smoke_corpus.py
                See docs/PHASE_2_BENCHMARK.md.
                """)
        }

        let corpus = try BenchmarkCorpus.load(from: directory)
        let selection = ProcessInfo.processInfo.environment["BENCHMARK_ENGINE"]?.lowercased()

        let engine: any TranscriptionService
        switch selection {
        case "whisperkit":
            // Downloading and loading Whisper takes far longer than a unit test
            // is normally allowed. The runner prepares each profile itself.
            executionTimeAllowance = 3600
            engine = WhisperKitTranscriptionService()
        case "apple":
            executionTimeAllowance = 1800
            engine = AppleSpeechTranscriptionService()
        default:
            let fake = FakeTranscriptionService()
            fake.setResult(.fixture(words: [("placeholder", 0.5)]))
            engine = fake
        }

        let report = await BenchmarkRunner.run(engine: engine, corpus: corpus, directory: directory)
        let markdown = report.markdown()
        print("\n\(markdown)\n")

        let reportURL = directory.appendingPathComponent("report-\(report.engineIdentifier).md")
        try markdown.write(to: reportURL, atomically: true, encoding: .utf8)

        // The only harness invariant: nothing is silently dropped. Whether an
        // engine can serve a given language is a measurement, not a test
        // failure, so an engine that scores nothing still produces a report.
        XCTAssertEqual(
            report.overall.sampleCount + report.failures.count,
            corpus.samples.count,
            "every sample must be either scored or reported as a failure"
        )

        if !report.failures.isEmpty {
            print("\n\(report.failures.count) of \(corpus.samples.count) samples were not scored:")
            for failure in report.failures { print("  - \(failure)") }
        }
    }

    static var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmark")
    }
}
