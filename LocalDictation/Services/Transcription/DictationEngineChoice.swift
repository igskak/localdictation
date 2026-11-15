import Foundation

/// Which recognizer dictation uses. Whisper unless a tester asked otherwise.
///
/// Parakeet is ten times faster than Whisper on an M1 and writes questions no
/// better (docs/PUNCTUATION_BENCHMARK.md), so it is not a product choice yet;
/// it is a switch for trying it on a real voice:
///
///     defaults write com.witnessmac.Witness DictationEngine parakeet-ultra
///
/// and a relaunch. `parakeet-v3` selects the original model; deleting the key
/// returns to Whisper. The Notetaker keeps Whisper either way, because its
/// long-form path is built on WhisperKit.
enum DictationEngineChoice: String, Sendable {
    case whisper
    case parakeetUltra = "parakeet-ultra"
    case parakeetV3 = "parakeet-v3"

    static let defaultsKey = "DictationEngine"

    static var current: DictationEngineChoice {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .whisper
    }

    /// The engine for dictation, reusing the app's Whisper instance when the
    /// choice is Whisper so the model is never loaded twice.
    func engine(sharing whisper: WhisperKitTranscriptionService) -> any TranscriptionService {
        switch self {
        case .whisper: whisper
        case .parakeetUltra: ParakeetTranscriptionService(variant: .ultra)
        case .parakeetV3: ParakeetTranscriptionService(variant: .v3)
        }
    }
}
