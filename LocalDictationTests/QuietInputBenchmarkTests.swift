import Foundation
import XCTest
@testable import Witness

/// What a raw microphone array costs recognition.
///
/// While another app runs voice processing, the built-in microphone hands
/// everyone else three raw array channels about 30 dB below the processed one.
/// Slice 1 and slice 2 make sure that signal reaches the engine at all; this
/// measures whether the engine can still read it, which is what decides whether
/// the finished utterance has to be normalized before transcription.
///
/// Runs only with a corpus installed and `BENCHMARK_ENGINE` set, like every
/// other corpus-backed measurement. See `docs/PHASE_2_BENCHMARK.md`.
final class QuietInputBenchmarkTests: XCTestCase {
    /// How far below normal the raw channels were measured to be.
    static let attenuationDecibels: Double = 30

    func testQuietInputAgainstTheNormalCorpus() async throws {
        let directory = BenchmarkRunnerTests.corpusDirectory
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(BenchmarkCorpus.manifestName).path
        ) else {
            throw XCTSkip("No corpus installed at \(directory.path). See docs/PHASE_2_BENCHMARK.md.")
        }
        let selection = ProcessInfo.processInfo.environment["BENCHMARK_ENGINE"]?.lowercased()
        guard let selection, selection != "fake" else {
            throw XCTSkip("Set BENCHMARK_ENGINE=whisperkit to measure a real engine")
        }

        let corpus = try BenchmarkCorpus.load(from: directory)
        executionTimeAllowance = 7200

        let normal = await BenchmarkRunner.run(
            engine: Self.engine(selection),
            corpus: corpus,
            directory: directory
        )
        let quiet = await BenchmarkRunner.run(
            engine: Self.engine(selection),
            corpus: corpus,
            directory: directory,
            attenuationDecibels: Self.attenuationDecibels
        )

        let markdown = Self.comparison(normal: normal, quiet: quiet, corpus: corpus)
        print("\n\(markdown)\n")
        try markdown.write(
            to: directory.appendingPathComponent("report-quiet-\(normal.engineIdentifier).md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            normal.overall.sampleCount, quiet.overall.sampleCount,
            "Both passes must score the same samples, or the comparison means nothing"
        )
    }

    private static func engine(_ selection: String) -> any TranscriptionService {
        switch selection {
        case "apple": AppleSpeechTranscriptionService()
        default: WhisperKitTranscriptionService()
        }
    }

    private static func comparison(
        normal: BenchmarkReport,
        quiet: BenchmarkReport,
        corpus: BenchmarkCorpus
    ) -> String {
        func percent(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1f%%", value * 100)
        }
        func delta(_ before: Double?, _ after: Double?) -> String {
            guard let before, let after else { return "n/a" }
            return String(format: "%+.1f pp", (after - before) * 100)
        }
        func row(_ label: String, _ before: BenchmarkAggregate, _ after: BenchmarkAggregate) -> String {
            var cells: [String] = [label, "\(before.sampleCount)"]
            cells.append(percent(before.word.rate))
            cells.append(percent(after.word.rate))
            cells.append(delta(before.word.rate, after.word.rate))
            cells.append(percent(before.character.rate))
            cells.append(percent(after.character.rate))
            cells.append(delta(before.character.rate, after.character.rate))
            return "| " + cells.joined(separator: " | ") + " |"
        }

        var lines: [String] = []
        lines.append("# Quiet input: \(Int(attenuationDecibels)) dB attenuation")
        lines.append("")
        lines.append("Engine: \(normal.engineName) (`\(normal.engineIdentifier)`)")
        lines.append("Corpus: \(corpus.name) · \(normal.overall.sampleCount) samples · \(normal.machine)")
        lines.append("")
        lines.append("| Language | Samples | WER normal | WER quiet | Δ WER | CER normal | CER quiet | Δ CER |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

        for language in normal.byLanguage.keys.sorted() {
            guard let before = normal.byLanguage[language], let after = quiet.byLanguage[language] else { continue }
            lines.append(row(language.displayName, before, after))
        }
        lines.append(row("**Overall**", normal.overall, quiet.overall))
        lines.append("")
        lines.append("Unscored samples: \(normal.failures.count) normal, \(quiet.failures.count) quiet.")
        for failure in quiet.failures { lines.append("  - quiet: \(failure)") }
        return lines.joined(separator: "\n")
    }
}
