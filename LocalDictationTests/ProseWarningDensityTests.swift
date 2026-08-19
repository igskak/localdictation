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
        lines.append("| Language | Samples | Words | Marks | Marks/100 words | Reviews |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for language in SpeechLanguage.allCases {
            guard let aggregate = report.byLanguage[language] else { continue }
            lines.append(
                """
                | \(language.rawValue) | \(aggregate.sampleCount) | \(aggregate.wordCount) \
                | \(aggregate.falseWarnings) | \(String(format: "%.1f", aggregate.falseWarningDensity ?? 0)) \
                | \(String(format: "%.0f %%", (aggregate.reviewRate ?? 0) * 100)) |
                """
            )
        }
        let overall = report.overall
        lines.append(
            """
            | all | \(overall.sampleCount) | \(overall.wordCount) | \(overall.falseWarnings) \
            | \(String(format: "%.1f", overall.falseWarningDensity ?? 0)) \
            | \(String(format: "%.0f %%", (overall.reviewRate ?? 0) * 100)) |
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

    /// The number that matters in Phase 4: how often a sentence with nothing
    /// wrong in it interrupts the user on the way into their document.
    ///
    /// The bound is a regression guard, not a target. It is set above what the
    /// engine currently does so an unrelated change that starts marking prose
    /// fails here rather than in someone's afternoon.
    func testOrdinaryProseRarelyInterrupts() throws {
        let rate = try XCTUnwrap(report().overall.reviewRate)
        XCTAssertLessThanOrEqual(
            rate,
            0.25,
            "more than a quarter of ordinary sentences interrupting is a review nobody reads"
        )
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
