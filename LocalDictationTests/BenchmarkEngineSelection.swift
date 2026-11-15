import Foundation
@testable import Witness

/// The engine an opt-in benchmark run measures, from the environment:
///
/// - `BENCHMARK_ENGINE`: `whisperkit`, `parakeet-v3` or `parakeet-ultra`;
/// - `BENCHMARK_MODEL`: a WhisperKit variant (default: the shipped one);
/// - `BENCHMARK_PROMPT=style`: Whisper conditioned on
///   `PunctuationBenchmark.stylePrompts`.
///
/// Nil when no real engine was asked for, so a test can skip.
struct BenchmarkEngineSelection {
    let engine: any TranscriptionService
    /// Shown in a report's heading.
    let label: String
    /// Used in a report's file name.
    let fileStem: String

    init?(environment: [String: String]) {
        switch environment["BENCHMARK_ENGINE"]?.lowercased() {
        case "whisperkit":
            let model = environment["BENCHMARK_MODEL"] ?? WhisperKitTranscriptionService.defaultModelVariant
            let prompted = environment["BENCHMARK_PROMPT"]?.lowercased() == "style"
            engine = WhisperKitTranscriptionService(
                modelVariant: model,
                decodingPrompts: prompted ? PunctuationBenchmark.stylePrompts : [:]
            )
            label = model + (prompted ? " + style prompt" : "")
            fileStem = model + (prompted ? "-prompt" : "")
        case "parakeet-v3", "parakeet":
            engine = ParakeetTranscriptionService(variant: .v3)
            label = "Parakeet TDT 0.6B v3"
            fileStem = "parakeet-v3"
        case "parakeet-ultra":
            engine = ParakeetTranscriptionService(variant: .ultra)
            label = "Parakeet Ultra"
            fileStem = "parakeet-ultra"
        default:
            return nil
        }
    }
}
