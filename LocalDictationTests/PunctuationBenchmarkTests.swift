import XCTest
@testable import Witness

/// The punctuation benchmark scores what Whisper wrote and what the app would
/// insert, side by side. The unit tests pin that split down without audio; the
/// last test runs a real engine over an installed corpus.
final class PunctuationBenchmarkTests: XCTestCase {
    private func sample(_ reference: String, language: SpeechLanguage = .russian, kind: String? = "yes-no") -> BenchmarkSample {
        BenchmarkSample(audio: "\(language.rawValue)/0001.wav", reference: reference, language: language, profile: nil, kind: kind)
    }

    /// The case behind the whole stand: Whisper leaves the end open and the
    /// app's own rule turns a question into a statement.
    func testAnOpenEndBecomesAPeriodOnlyInTheInsertedText() {
        let transcript = Transcript.fixture(
            words: [("ты", 0.9), ("придёшь", 0.9), ("завтра", 0.9)],
            profile: .russian
        )

        let result = PunctuationBenchmark.score(
            transcript: transcript,
            sample: sample("Ты придёшь завтра?"),
            audioDuration: 1
        )

        XCTAssertTrue(result.engineLeftEndOpen)
        XCTAssertEqual(result.engine.count(reference: .question, hypothesis: .unmarked), 1)
        XCTAssertEqual(result.insertedText, "Ты придёшь завтра.")
        XCTAssertEqual(result.inserted.count(reference: .question, hypothesis: .period), 1)
    }

    func testAQuestionWhisperWroteSurvivesInsertion() {
        let transcript = Transcript.fixture(
            words: [("Kommst", 0.9), ("du", 0.9), ("morgen?", 0.9)],
            profile: .german
        )

        let result = PunctuationBenchmark.score(
            transcript: transcript,
            sample: sample("Kommst du morgen?", language: .german),
            audioDuration: 1
        )

        XCTAssertFalse(result.engineLeftEndOpen)
        XCTAssertEqual(try XCTUnwrap(result.inserted.recall(.question)), 1)
    }

    func testTheReportSeparatesEngineFromInsertedAndListsQuestionMistakes() {
        let open = PunctuationBenchmark.score(
            transcript: .fixture(words: [("ты", 0.9), ("придёшь", 0.9)], profile: .russian),
            sample: sample("Ты придёшь?"),
            audioDuration: 1
        )
        let right = PunctuationBenchmark.score(
            transcript: .fixture(words: [("Kommst", 0.9), ("du?", 0.9)], profile: .german),
            sample: BenchmarkSample(audio: "de/0001.wav", reference: "Kommst du?", language: .german, profile: nil, kind: "yes-no"),
            audioDuration: 1
        )
        let report = PunctuationReport(
            variant: "fake",
            corpusName: "unit",
            machine: "test",
            results: [open, right],
            failures: ["uk/0002.wav: missing"]
        )

        let markdown = report.markdown()
        let russian = SpeechLanguage.russian.displayName
        XCTAssertTrue(markdown.contains("| \(russian) | engine | 1 |"))
        XCTAssertTrue(markdown.contains("| \(russian) | inserted | 1 |"))
        XCTAssertTrue(markdown.contains("| yes-no | 1/1 | 0/1 |"), "German first, then Russian")
        XCTAssertTrue(markdown.contains("### Question mistakes"))
        XCTAssertTrue(markdown.contains("inserted: `Ты придёшь.`"))
        XCTAssertFalse(markdown.contains("**de/0001.wav**"), "a question written as one is not a mistake")
        XCTAssertTrue(markdown.contains("uk/0002.wav: missing"))
    }

    func testOlderManifestsWithoutAKindStillDecode() throws {
        let json = #"{"name":"old","samples":[{"audio":"a.wav","reference":"a","language":"en"}]}"#
        let corpus = try JSONDecoder().decode(BenchmarkCorpus.self, from: Data(json.utf8))
        XCTAssertNil(corpus.samples[0].kind)
    }

    // MARK: - Corpus-gated run

    /// Runs Whisper over the punctuation corpus. Opt-in, like every engine run:
    ///
    ///     TEST_RUNNER_BENCHMARK_ENGINE=whisperkit \
    ///     TEST_RUNNER_BENCHMARK_CORPUS=/path/to/Benchmark/punctuation-tts \
    ///     xcodebuild test ... -only-testing:LocalDictationTests/PunctuationBenchmarkTests/testRunAgainstThePunctuationCorpusIfPresent
    ///
    /// `BENCHMARK_MODEL` picks a WhisperKit variant (default: the shipped one)
    /// and `BENCHMARK_PROMPT=style` conditions the decoder on
    /// `PunctuationBenchmark.stylePrompts`. The report lands next to the
    /// corpus as `report-<variant>.md`.
    func testRunAgainstThePunctuationCorpusIfPresent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BENCHMARK_ENGINE"]?.lowercased() == "whisperkit" else {
            throw XCTSkip("Needs the Whisper model; run with TEST_RUNNER_BENCHMARK_ENGINE=whisperkit")
        }
        let directory = environment["BENCHMARK_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? BenchmarkRunnerTests.corpusDirectory.appendingPathComponent("punctuation-tts")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(BenchmarkCorpus.manifestName).path) else {
            throw XCTSkip("No punctuation corpus at \(directory.path); see Tools/make_punctuation_corpus.py")
        }
        executionTimeAllowance = 7200

        let model = environment["BENCHMARK_MODEL"] ?? WhisperKitTranscriptionService.defaultModelVariant
        let prompted = environment["BENCHMARK_PROMPT"]?.lowercased() == "style"
        let engine = WhisperKitTranscriptionService(
            modelVariant: model,
            decodingPrompts: prompted ? PunctuationBenchmark.stylePrompts : [:]
        )
        let variant = model + (prompted ? " + style prompt" : "")

        let corpus = try BenchmarkCorpus.load(from: directory)
        let report = await PunctuationBenchmark.run(engine: engine, variant: variant, corpus: corpus, directory: directory)
        let markdown = report.markdown()
        print("\n\(markdown)\n")

        let fileName = "report-\(model)\(prompted ? "-prompt" : "").md"
        try markdown.write(to: directory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            report.results.count + report.failures.count,
            corpus.samples.count,
            "every sample must be either scored or reported as a failure"
        )
    }
}
