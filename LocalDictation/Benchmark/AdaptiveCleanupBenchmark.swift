#if DEBUG
import Foundation

/// A text-only cleanup fixture. Real recordings remain in the private,
/// consented corpus outside the repository; this manifest is safe to commit
/// because it contains only deliberately authored test phrases.
struct AdaptiveCleanupSample: Sendable, Codable, Equatable {
    struct Context: Sendable, Codable, Equatable {
        let category: String
        let textBeforeCaret: String
        let textAfterCaret: String
        let hasSelection: Bool
    }

    struct TokenTiming: Sendable, Codable, Equatable {
        let lowerBound: Int
        let upperBound: Int
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Double?
    }

    let identifier: String
    let language: SpeechLanguage
    let profile: String?
    let raw: String
    let ideal: String
    let context: Context?
    let protectedValues: [String]
    let allowedEditKinds: [String]
    var timings: [TokenTiming]? = nil

    var languageProfile: LanguageProfile {
        profile.flatMap(LanguageProfile.profile(id:)) ?? LanguageProfile(language)
    }
}

struct AdaptiveCleanupManifest: Sendable, Codable, Equatable {
    let name: String
    let samples: [AdaptiveCleanupSample]

    static let manifestName = "flow-light.json"

    static func load(from directory: URL) throws -> AdaptiveCleanupManifest {
        let url = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkCorpusError.manifestMissing(url.path)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

struct AdaptiveCleanupSampleResult: Sendable, Equatable {
    let identifier: String
    let language: SpeechLanguage
    let raw: String
    let ideal: String
    let output: String
    let editPrecision: Double
    let editRecall: Double
    let protectedValuesPreserved: Bool
    let punctuationF1: Double
    let lineBreakF1: Double
    let correctionEffort: Int
    let processingDuration: TimeInterval
    let unexpectedEditKinds: [String]
    let conservativeLexicallyPreserved: Bool?
    let idempotent: Bool?
}

struct AdaptiveCleanupReport: Sendable, Equatable {
    let name: String
    let results: [AdaptiveCleanupSampleResult]

    var byLanguage: [SpeechLanguage: [AdaptiveCleanupSampleResult]] {
        Dictionary(grouping: results, by: \.language)
    }

    var p50Duration: TimeInterval { percentile(0.50) }
    var p95Duration: TimeInterval { percentile(0.95) }

    private func percentile(_ fraction: Double) -> TimeInterval {
        let values = results.map(\.processingDuration).sorted()
        guard !values.isEmpty else { return 0 }
        let index = Int((Double(values.count - 1) * fraction).rounded(.up))
        return values[min(index, values.count - 1)]
    }
}

enum AdaptiveCleanupBenchmarkMode: Sendable {
    case legacyConservative
    case legacyClean
    case conservative
    case clean
}

private struct ConfiguredCleanupBenchmarkService: CleanupService {
    let mode: AdaptiveCleanupBenchmarkMode

    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult {
        switch mode {
        case .legacyConservative:
            return ConservativeCleanupService().clean(raw, language: language, options: options)
        case .legacyClean:
            var cleanOptions = options
            cleanOptions.level = .clean
            cleanOptions.timing = nil
            return Phase9LegacyCleanupService().clean(raw, language: language, options: cleanOptions)
        case .conservative:
            return ConservativePipeline().clean(raw, language: language, options: options)
        case .clean:
            var cleanOptions = options
            cleanOptions.level = .clean
            return AdaptiveCleanupService().clean(raw, language: language, options: cleanOptions)
        }
    }
}

enum AdaptiveCleanupBenchmark {
    static func run(manifest: AdaptiveCleanupManifest, mode: AdaptiveCleanupBenchmarkMode) -> AdaptiveCleanupReport {
        run(manifest: manifest, service: ConfiguredCleanupBenchmarkService(mode: mode))
    }

    static func run(
        manifest: AdaptiveCleanupManifest,
        service: any CleanupService
    ) -> AdaptiveCleanupReport {
        let clock = ContinuousClock()
        let results = manifest.samples.map { sample in
            let start = clock.now
            let context = sample.context.flatMap { fixture -> DictationTextContext? in
                guard let category = ApplicationCategory(rawValue: fixture.category) else { return nil }
                return DictationTextContext(category: category, fieldRole: .editableText,
                                            textBeforeCaret: fixture.textBeforeCaret,
                                            textAfterCaret: fixture.textAfterCaret,
                                            hasSelection: fixture.hasSelection)
            }
            let tokens = sample.timings?.compactMap { timing -> CleanupTokenTiming? in
                guard timing.lowerBound >= 0, timing.upperBound >= timing.lowerBound else { return nil }
                return CleanupTokenTiming(rawRange: timing.lowerBound..<timing.upperBound,
                                          start: timing.start, end: timing.end, confidence: timing.confidence)
            }
            let timing = tokens.flatMap { tokens in
                tokens.count == sample.timings?.count ? CleanupTimingEvidence.validated(tokens, raw: sample.raw) : nil
            }
            let options = CleanupOptions(context: context, timing: timing)
            let cleanup = service.clean(sample.raw, language: sample.language, options: options)
            let duration = start.duration(to: clock.now).timeInterval
            return AdaptiveCleanupScorer.score(
                sample: sample, cleanup: cleanup, duration: duration,
                conservativeLexicallyPreserved: StructuralCleanupScorer.conservativeLexicallyPreserved(cleanup),
                idempotent: StructuralCleanupScorer.isIdempotent(cleanup, service: service, options: options)
            )
        }
        return AdaptiveCleanupReport(name: manifest.name, results: results)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
