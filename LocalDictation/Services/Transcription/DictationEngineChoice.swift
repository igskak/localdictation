import Foundation

/// The test build keeps one selection for both entry points. Freeze the active
/// selection at launch: changing Settings must never switch an in-flight call.
enum DictationEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case whisper
    case whisperLarge = "whisper-large-v3"
    case parakeetUltra = "parakeet-ultra"
    case parakeetV3 = "parakeet-v3"

    static let defaultsKey = "DictationEngine"
    static let fullWhisperVariant = "openai_whisper-large-v3_turbo"
    static let active = current

    var id: String { rawValue }

    static func saved(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .whisper
    }

    static var current: Self { saved(in: .standard) }

    static func allowsRestart(dictation: RecordingState, meetingIsActive: Bool) -> Bool {
        !dictation.isBusy && !meetingIsActive
    }

    var title: String {
        switch self {
        case .whisper: "Whisper large-v3 turbo"
        case .whisperLarge: "Whisper large-v3 (full)"
        case .parakeetUltra: "Parakeet Ultra"
        case .parakeetV3: "Parakeet TDT v3"
        }
    }

    var detail: String {
        switch self {
        case .whisper:
            "The current baseline. Faster than full large-v3; supports all Witness languages."
        case .whisperLarge:
            "The full 32-layer decoder, about 3.2 GB. Slower than turbo; supports all Witness languages."
        case .parakeetUltra:
            "A faster experimental recognizer for 25 European languages. Language selection is less strict than Whisper."
        case .parakeetV3:
            "The original Parakeet v3 for comparison with Ultra. Supports the same 25 European languages."
        }
    }

    func supports(_ profile: LanguageProfile) -> Bool {
        switch self {
        case .whisper, .whisperLarge: true
        case .parakeetUltra, .parakeetV3:
            profile.languages.allSatisfy { ParakeetTranscriptionService.languages.contains($0.rawValue) }
        }
    }

    /// Only the selected engine is constructed. Whisper clients retain their
    /// separate language histories; both Parakeet clients share one serial queue.
    func makeClients() -> SpeechEngineClients {
        switch self {
        case .whisper, .whisperLarge:
            let speech = WhisperKitTranscriptionService(modelVariant: self == .whisper
                ? WhisperKitTranscriptionService.defaultModelVariant : Self.fullWhisperVariant)
            return SpeechEngineClients(dictation: speech, meeting: speech.meetingClient)
        case .parakeetUltra, .parakeetV3:
            let speech = ParakeetTranscriptionService(variant: self == .parakeetUltra ? .ultra : .v3)
            return SpeechEngineClients(dictation: speech, meeting: speech)
        }
    }
}

struct SpeechEngineClients: Sendable {
    let dictation: any TranscriptionService
    let meeting: any TranscriptionService
}
