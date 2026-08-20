import XCTest
@testable import LocalDictation

/// What the review step costs on text that is simply correct.
///
/// `docs/PHASE_3.md` already said false warnings are a budget rather than a
/// side effect, and that a rise in density is a regression. Phase 4 is where
/// the budget is actually spent: until now a needless mark added a strip to a
/// panel the user had opened anyway, and now it interrupts a path that would
/// otherwise show no window at all.
///
/// Deterministic and model-free by construction — the hypothesis *is* the
/// reference, so every mark is a false warning by definition.
final class ProseWarningDensityTests: XCTestCase {
    private func report() -> RiskReport {
        RiskBenchmark.runOnReferences(corpus: ProseCorpus.corpus)
    }

    /// Writes the table the phase report quotes, next to the other benchmark
    /// output. Not an assertion: the numbers belong in a document, and the
    /// bounds below are what guard them.
    func testReportsDensityPerLanguage() throws {
        let report = report()
        var lines = ["", "Ordinary prose — risk engine on correct text", ""]
        lines.append("| Language | Samples | Words | Marks | Marks/100 words | Indicator |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for language in SpeechLanguage.allCases {
            guard let aggregate = report.byLanguage[language] else { continue }
            lines.append(
                """
                | \(language.rawValue) | \(aggregate.sampleCount) | \(aggregate.wordCount) \
                | \(aggregate.falseWarnings) | \(String(format: "%.1f", aggregate.falseWarningDensity ?? 0)) \
                | \(String(format: "%.0f %%", (aggregate.attentionRate ?? 0) * 100)) |
                """
            )
        }
        let overall = report.overall
        lines.append(
            """
            | all | \(overall.sampleCount) | \(overall.wordCount) | \(overall.falseWarnings) \
            | \(String(format: "%.1f", overall.falseWarningDensity ?? 0)) \
            | \(String(format: "%.0f %%", (overall.attentionRate ?? 0) * 100)) |
            """
        )
        lines.append("")
        lines.append("By signal: \(overall.falseWarningsByCategory.sorted { $0.key < $1.key })")

        let markdown = lines.joined(separator: "\n")
        print(markdown)
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmark")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? markdown.write(
            to: directory.appendingPathComponent("prose-density.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The number that matters in Phase 5: how often a sentence with nothing
    /// wrong in it lights the indicator.
    ///
    /// Nothing interrupts any more, so this no longer measures lost time — it
    /// measures whether the triangle still means anything. One that appears
    /// after a quarter of ordinary sentences is one the user stops seeing, and
    /// then it is worth less than no triangle at all.
    ///
    /// The bound is a regression guard, not a target. It is set above what the
    /// engine currently does so an unrelated change that starts marking prose
    /// fails here rather than in someone's afternoon.
    func testOrdinaryProseRarelyLightsTheIndicator() throws {
        let rate = try XCTUnwrap(report().overall.attentionRate)
        XCTAssertLessThanOrEqual(
            rate,
            0.25,
            "an indicator this common is one nobody looks at"
        )
    }

    /// The regression that started this phase, as a number.
    ///
    /// A correctly recognized product or person name must never be the reason
    /// the user is told to check something. The entity heuristic still marks
    /// them — it is a capitalization rule and cannot know better — but it is
    /// priced below the attention threshold, so the marks stay inside a review
    /// the user opened for another reason.
    func testCorrectlyRecognizedNamesNeverLightTheIndicator() throws {
        let names = BenchmarkCorpus(
            name: "names",
            samples: ProseCorpus.withNames.enumerated().map { offset, entry in
                BenchmarkSample(
                    audio: "name-\(offset).wav",
                    reference: entry.1,
                    language: entry.0,
                    profile: nil
                )
            }
        )

        let rate = try XCTUnwrap(RiskBenchmark.runOnReferences(corpus: names).overall.attentionRate)
        XCTAssertEqual(rate, 0, "a name that came out right is not worth interrupting anyone about")

        // What the single Phase 3 threshold did with the same sentences, kept
        // as an assertion so the improvement is a measured fact rather than a
        // claim in a document. Six of these eight interrupted; the two that did
        // not are German, where the capitalization heuristic is switched off
        // because every noun there is capitalized.
        let phase3 = try XCTUnwrap(
            RiskBenchmark.runOnReferences(
                corpus: names,
                policy: ReviewPolicy(attentionThreshold: 0.5, displayThreshold: 0.5)
            ).overall.attentionRate
        )
        XCTAssertEqual(phase3, 0.75, accuracy: 0.001, "the old single threshold interrupted on every name it could see")
    }

    func testDensityStaysWithinItsBudget() throws {
        let density = try XCTUnwrap(report().overall.falseWarningDensity)
        XCTAssertLessThanOrEqual(density, 6, "marks per hundred words of correct prose")
    }

    /// Cleanup may never change meaning, on prose as on anything else.
    func testCleanupPreservesMeaningOnOrdinaryProse() throws {
        let preservation = try XCTUnwrap(report().overall.semanticPreservation)
        XCTAssertEqual(preservation, 1, accuracy: 0.0001)
    }

    /// German capitalizes every noun, so a capitalized-mid-sentence heuristic
    /// would mark most of this corpus. It is switched off for German, and this
    /// is the corpus where that either holds or is obvious.
    func testGermanNounsAreNotMistakenForNames() throws {
        let german = try XCTUnwrap(report().byLanguage[.german])
        let entityMarks = german.falseWarningsByCategory["entity"] ?? 0
        XCTAssertLessThanOrEqual(
            entityMarks,
            1,
            "capitalized German nouns must not read as names"
        )
    }
}
