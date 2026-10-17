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
        XCTAssertGreaterThanOrEqual(report.p50Duration, 0)
        XCTAssertGreaterThanOrEqual(report.p95Duration, report.p50Duration)
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
