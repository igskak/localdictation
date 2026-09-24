import XCTest
@testable import Witness

/// Reusing the encoder output must change nothing but the time.
///
/// Runs every sample twice on the real model — once with WhisperKit's own
/// encoder, once with the reusing one — and requires the same language, the
/// same text, and the same tokens with the same timings and confidences. Any
/// difference at all is a failure, because the whole claim of the reuse is that
/// the detector and the decoder receive exactly the numbers they received
/// before.
///
/// Opt-in like the benchmark, because it needs the model and minutes:
///
///     TEST_RUNNER_BENCHMARK_ENGINE=whisperkit xcodebuild test \
///       -only-testing:LocalDictationTests/EncoderReuseParityTests ...
///
/// It reads `Benchmark/corpus.json` and, when present, the
/// `Benchmark/leading-silence/` corpus from `Tools/make_leading_silence_corpus.py`.
/// That second one matters most: its profiles are mixed, which is the only case
/// where anything is reused, and its pauses are where 0.6.6 went wrong.
/// `TEST_RUNNER_BENCHMARK_CORPUS` points elsewhere, for a worktree whose own
/// `Benchmark/` is empty.
final class EncoderReuseParityTests: XCTestCase {
    private struct Run {
        var transcripts: [String: Transcript] = [:]
        var seconds: [String: TimeInterval] = [:]
    }

    private static var corpusRoot: URL {
        if let override = ProcessInfo.processInfo.environment["BENCHMARK_CORPUS"] {
            return URL(fileURLWithPath: override)
        }
        return BenchmarkRunnerTests.corpusDirectory
    }

    private func corpora() throws -> [(name: String, directory: URL, corpus: BenchmarkCorpus)] {
        let candidates = [Self.corpusRoot, Self.corpusRoot.appendingPathComponent("leading-silence")]
        return try candidates.compactMap { directory in
            let manifest = directory.appendingPathComponent(BenchmarkCorpus.manifestName)
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            let corpus = try BenchmarkCorpus.load(from: directory)
            return (corpus.name, directory, corpus)
        }
    }

    private func run(reusing: Bool, over corpora: [(name: String, directory: URL, corpus: BenchmarkCorpus)]) async throws -> Run {
        let service = WhisperKitTranscriptionService(reusesEncoderOutput: reusing)
        var run = Run()
        for (name, directory, corpus) in corpora {
            for sample in corpus.samples {
                let profile = sample.languageProfile
                try await service.prepare(for: profile)
                let utterance = try corpus.utterance(for: sample, in: directory)
                let transcript = try await service.transcribe(utterance, profile: profile)
                let key = "\(name)/\(sample.audio)"
                run.transcripts[key] = transcript
                run.seconds[key] = transcript.processingDuration
            }
        }
        return run
    }

    func testReusingTheEncoderOutputChangesNothingButTheTime() async throws {
        guard ProcessInfo.processInfo.environment["BENCHMARK_ENGINE"]?.lowercased() == "whisperkit" else {
            throw XCTSkip("Needs the Whisper model; run with TEST_RUNNER_BENCHMARK_ENGINE=whisperkit")
        }
        let corpora = try corpora()
        guard !corpora.isEmpty else {
            throw XCTSkip("No corpus at \(Self.corpusRoot.path); see Tools/make_smoke_corpus.py")
        }
        executionTimeAllowance = 3600

        // One engine at a time, so two copies of the model are never resident.
        let reference = try await run(reusing: false, over: corpora)
        let candidate = try await run(reusing: true, over: corpora)

        var mismatches: [String] = []
        for key in reference.transcripts.keys.sorted() {
            let before = reference.transcripts[key]
            let after = candidate.transcripts[key]
            if before?.detectedLanguage != after?.detectedLanguage { mismatches.append("\(key): language") }
            if before?.text != after?.text { mismatches.append("\(key): text") }
            if before?.tokens != after?.tokens { mismatches.append("\(key): tokens") }
        }

        var report = ["| Corpus | Samples | Mixed profile | Without reuse | With reuse | Saved per utterance |", "| --- | ---: | --- | ---: | ---: | ---: |"]
        for (name, _, corpus) in corpora {
            let keys = corpus.samples.map { "\(name)/\($0.audio)" }
            let before = keys.compactMap { reference.seconds[$0] }.reduce(0, +)
            let after = keys.compactMap { candidate.seconds[$0] }.reduce(0, +)
            let mixed = corpus.samples.allSatisfy(\.languageProfile.isMixed) ? "yes" : "no"
            report.append(String(
                format: "| %@ | %d | %@ | %.2f s | %.2f s | %.2f s |",
                name, keys.count, mixed, before, after, (before - after) / Double(max(keys.count, 1))
            ))
        }
        report.append("")
        report.append("Mismatches: \(mismatches.count)")
        report.append(contentsOf: mismatches)
        try report.joined(separator: "\n").write(
            to: Self.corpusRoot.appendingPathComponent("report-encoder-reuse.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(mismatches, [], "Reuse must be invisible in the result")
    }
}
