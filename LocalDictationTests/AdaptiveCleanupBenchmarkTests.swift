import XCTest
@testable import Witness

#if DEBUG
final class AdaptiveCleanupBenchmarkTests: XCTestCase {
    private let manifest = AdaptiveCleanupManifest(
        name: "conservative-baseline",
        samples: [
            AdaptiveCleanupSample(
                identifier: "en-spacing",
                language: .english,
                profile: "en",
                raw: "  hello world  ",
                ideal: "Hello world.",
                context: nil,
                protectedValues: [],
                allowedEditKinds: ["spacing", "capitalization", "punctuation"]
            ),
            AdaptiveCleanupSample(
                identifier: "de-protected",
                language: .german,
                profile: nil,
                raw: "betrag 1450 euro",
                ideal: "Betrag 1450 euro.",
                context: nil,
                protectedValues: ["1450"],
                allowedEditKinds: ["capitalization", "punctuation"]
            ),
        ]
    )

    func testManifestRoundTripsAndResolvesProfiles() throws {
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AdaptiveCleanupManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.samples[0].languageProfile, .english)
    }

    func testConservativeBaselineScoresPerLanguageAndLatency() {
        let report = AdaptiveCleanupBenchmark.run(manifest: manifest, service: ConservativeCleanupService())
        XCTAssertEqual(report.results.map(\.output), ["Hello world.", "Betrag 1450 euro."])
        XCTAssertEqual(Set(report.byLanguage.keys), [.english, .german])
        XCTAssertTrue(report.results.allSatisfy(\.protectedValuesPreserved))
        XCTAssertTrue(report.results.allSatisfy { $0.correctionEffort == 0 })
        XCTAssertTrue(report.results.allSatisfy { $0.conservativeLexicallyPreserved == true })
        XCTAssertTrue(report.results.allSatisfy { $0.idempotent == true })
        XCTAssertGreaterThanOrEqual(report.p50Duration, 0)
        XCTAssertGreaterThanOrEqual(report.p95Duration, report.p50Duration)
    }

    func testBenchmarkModesCompareTheSameRawSamples() {
        let fixture = AdaptiveCleanupManifest(name: "surface", samples: [
            AdaptiveCleanupSample(identifier: "percentage", language: .english, profile: nil,
                                  raw: "20 %", ideal: "20%", context: nil, protectedValues: ["20"],
                                  allowedEditKinds: ["surfaceNormalization"]),
        ])
        let legacy = AdaptiveCleanupBenchmark.run(manifest: fixture, mode: .legacyConservative)
        let current = AdaptiveCleanupBenchmark.run(manifest: fixture, mode: .conservative)
        let clean = AdaptiveCleanupBenchmark.run(manifest: fixture, mode: .clean)
        XCTAssertEqual(legacy.results[0].raw, current.results[0].raw)
        XCTAssertEqual(current.results[0].raw, clean.results[0].raw)
        XCTAssertTrue(legacy.results[0].output.contains("20 %"))
        XCTAssertTrue(current.results[0].output.contains("20%"))
        XCTAssertTrue(clean.results[0].output.contains("20%"))
    }

    func testBenchmarkPassesFixtureContextToCleanMode() {
        let context = AdaptiveCleanupSample.Context(category: "workMessaging", textBeforeCaret: "",
                                                    textAfterCaret: "", hasSelection: false)
        let sample = AdaptiveCleanupSample(identifier: "chat", language: .english, profile: nil,
                                           raw: "hello there", ideal: "Hello there", context: context,
                                           protectedValues: [], allowedEditKinds: [])
        let report = AdaptiveCleanupBenchmark.run(manifest: .init(name: "context", samples: [sample]), mode: .clean)
        XCTAssertEqual(report.results[0].output, "Hello there")
    }

    func testBenchmarkPassesValidatedTimingAndRejectsMalformedTiming() {
        var sample = AdaptiveCleanupSample(identifier: "duplicate", language: .english, profile: nil,
                                           raw: "hello hello", ideal: "Hello.", context: nil,
                                           protectedValues: [], allowedEditKinds: [])
        sample.timings = [
            .init(lowerBound: 0, upperBound: 5, start: 0, end: 1, confidence: 1),
            .init(lowerBound: 6, upperBound: 11, start: 0, end: 1, confidence: 1),
        ]
        var report = AdaptiveCleanupBenchmark.run(manifest: .init(name: "timing", samples: [sample]), mode: .conservative)
        XCTAssertEqual(report.results[0].output, "Hello.")
        sample.timings?[1] = .init(lowerBound: 11, upperBound: 6, start: 0, end: 1, confidence: 1)
        report = AdaptiveCleanupBenchmark.run(manifest: .init(name: "timing", samples: [sample]), mode: .conservative)
        XCTAssertEqual(report.results[0].output, "Hello hello.")
    }

    func testLexicalAndIdempotenceScoresDetectChangedFacts() {
        let service = ConservativePipeline()
        let raw = "um во - первых 20 %"
        let result = service.clean(raw, language: .english, options: CleanupOptions())
        XCTAssertTrue(StructuralCleanupScorer.conservativeLexicallyPreserved(result))
        XCTAssertTrue(StructuralCleanupScorer.isIdempotent(result, service: service, options: CleanupOptions()))
        let damaged = CleanupResult(raw: "amount 20", cleaned: "Amount 21.", edits: [],
                                    map: .identity(length: 9), language: .english)
        XCTAssertFalse(StructuralCleanupScorer.conservativeLexicallyPreserved(damaged))
    }

    func testBoundaryScoresPenalizeMarksAtWrongWordBoundary() {
        let sample = AdaptiveCleanupSample(identifier: "boundary", language: .english, profile: nil,
                                           raw: "hello world", ideal: "hello,\nworld", context: nil,
                                           protectedValues: [], allowedEditKinds: [])
        let cleanup = CleanupResult(raw: sample.raw, cleaned: "hello world,\n", edits: [],
                                    map: .identity(length: sample.raw.count), language: .english)
        let result = AdaptiveCleanupScorer.score(sample: sample, cleanup: cleanup)
        XCTAssertEqual(result.punctuationF1, 0)
        XCTAssertEqual(result.lineBreakF1, 0)
    }

    func testScorerReportsProtectedValueLossAndUnexpectedKinds() {
        let sample = manifest.samples[1]
        let cleanup = CleanupResult(
            raw: sample.raw,
            cleaned: "Betrag euro.",
            edits: [TextEdit(kind: .fillerRemoval, rawRange: 7..<12, cleanedRange: 7..<7, rawText: "1450 ", cleanedText: "")],
            map: .identity(length: sample.raw.count),
            language: .german
        )
        let result = AdaptiveCleanupScorer.score(sample: sample, cleanup: cleanup)
        XCTAssertFalse(result.protectedValuesPreserved)
        XCTAssertEqual(result.unexpectedEditKinds, ["fillerRemoval"])
        XCTAssertGreaterThan(result.correctionEffort, 0)
    }
}
#endif
