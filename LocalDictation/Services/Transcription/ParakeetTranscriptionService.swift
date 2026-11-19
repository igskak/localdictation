import FluidAudio
import Foundation
import NaturalLanguage

/// Candidate engine: NVIDIA Parakeet TDT 0.6B through FluidAudio (Apache-2.0),
/// either the original v3 or Ultra, its post-trained successor with the same
/// languages, tokenizer and speed.
///
/// Why it is worth measuring next to Whisper: it writes its own punctuation
/// and capitalization, covers 25 European languages including all four
/// verified ones, runs on the Neural Engine at roughly a hundred times real
/// time, and reports a confidence per token, which the risk engine needs.
/// FluidAudio is already in the app for the Notetaker's diarizer, so this adds
/// no dependency.
///
/// What it cannot do that Whisper can: be told the language. v3 decodes
/// whatever it hears; FluidAudio's hint only filters tokens by script, which
/// keeps German out of a Russian transcript but cannot tell Russian from
/// Ukrainian. The language reported back is therefore read from the text.
///
/// Weights are downloaded on an explicit action into Application Support, like
/// Whisper's, and never leave the Mac.
actor ParakeetTranscriptionService: TranscriptionService {
    enum Variant: String, Sendable, CaseIterable {
        case v3
        case ultra

        var version: AsrModelVersion {
            switch self {
            case .v3: .v3
            case .ultra: .ultra
            }
        }
    }

    /// The 25 languages of Parakeet TDT v3, in `SpeechLanguage` codes.
    static let languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    nonisolated let identifier: String
    nonisolated let displayName: String
    nonisolated var minimumAudioDuration: TimeInterval { ASRConstants.minimumAudioDurationSeconds }
    let variant: Variant

    private var manager: AsrManager?
    /// Single-flight load, for the same reason as Whisper's: actor isolation
    /// is released at every `await`, so a second caller would start a second
    /// load of the same weights.
    private var loadTask: Task<Void, any Error>?
    private var loadStartedAt: Date?
    private var inferenceTurns = InferenceTurns<CheckedContinuation<Void, Never>>()

    init(variant: Variant = .ultra) {
        self.variant = variant
        identifier = "parakeet-\(variant.rawValue)"
        displayName = variant == .ultra ? "Parakeet Ultra (TDT 0.6B)" : "Parakeet TDT 0.6B v3"
    }

    nonisolated func supports(_ profile: LanguageProfile) -> Bool {
        profile.languages.allSatisfy { Self.languages.contains($0.rawValue) }
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        if manager != nil { return .ready }
        if loadTask != nil {
            let phase: ModelPreparation.Phase = loadStartedAt.map { Date().timeIntervalSince($0) > 20 } == true ? .compilingForThisSystem : .loading
            return .preparing(ModelPreparation(phase: phase))
        }
        guard let directory = Self.modelDirectory(for: variant) else {
            return .failed("Could not locate Application Support")
        }
        return AsrModels.modelsExist(at: directory, version: variant.version)
            ? .unavailable("Speech model is installed but not loaded yet", needsUserAction: false)
            : .unavailable("The Parakeet speech model has not been downloaded yet", needsUserAction: true)
    }

    func prepare(for profile: LanguageProfile) async throws {
        _ = try await loadedManager()
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let load: Task<Void, any Error>
        if let loadTask {
            load = loadTask
        } else {
            loadStartedAt = Date()
            load = startLoad()
            loadTask = load
        }
        do {
            try await load.value
        } catch {
            if loadTask == load { loadTask = nil }
            throw error
        }
        guard let manager else {
            if loadTask == load { loadTask = nil }
            throw TranscriptionError.modelUnavailable("The Parakeet model is not loaded")
        }
        return manager
    }

    private func startLoad() -> Task<Void, any Error> {
        let variant = variant
        return Task { [self] in
            defer { loadStartedAt = nil }
            guard let directory = Self.modelDirectory(for: variant) else {
                throw TranscriptionError.modelUnavailable("Could not locate Application Support")
            }
            do {
                let models = try await AsrModels.downloadAndLoad(to: directory, version: variant.version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                install(manager)
            } catch let error as TranscriptionError {
                throw error
            } catch {
                throw TranscriptionError.modelPreparationFailed(
                    ModelPreparationFailure(error),
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func install(_ manager: AsrManager) {
        self.manager = manager
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        guard !utterance.samples.isEmpty else { throw TranscriptionError.emptyAudio }
        guard utterance.sampleRate == AudioTargetFormat.sampleRate else {
            throw TranscriptionError.engineFailure(
                "Parakeet expects 16 kHz audio, got \(Int(utterance.sampleRate)) Hz"
            )
        }
        guard manager != nil || loadTask != nil else {
            throw TranscriptionError.modelUnavailable("The speech model is not loaded yet.")
        }
        let manager = try await loadedManager()
        await beginInference()
        defer { inferenceTurns.leave()?.resume() }
        try Task.checkCancellation()

        let started = Date()
        let result: ASRResult
        do {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            result = try await manager.transcribe(
                utterance.samples,
                decoderState: &state,
                language: Self.scriptHint(for: profile)
            )
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        try Task.checkCancellation()

        let words = Self.words(from: result.tokenTimings ?? [])
        let text = words.map(\.text).joined(separator: " ")
        return Transcript.assemble(
            words: words,
            profile: profile,
            detectedLanguage: Self.language(of: text, in: profile),
            audioDuration: utterance.duration,
            processingDuration: Date().timeIntervalSince(started),
            engineIdentifier: identifier
        )
    }

    private func beginInference() async {
        guard !inferenceTurns.enter() else { return }
        await withCheckedContinuation { inferenceTurns.wait($0) }
    }

    // MARK: - Language

    /// A script filter only when every language in the profile shares one
    /// script, since the filter cannot choose between two.
    static func scriptHint(for profile: LanguageProfile) -> Language? {
        let scripts = Set(profile.languages.map(\.script))
        guard scripts.count == 1 else { return nil }
        return Language(rawValue: profile.primary.rawValue)
            ?? profile.languages.lazy.compactMap { Language(rawValue: $0.rawValue) }.first
    }

    /// The profile language the text is written in. Single-language profiles
    /// answer without looking; mixed ones ask NaturalLanguage, constrained to
    /// the profile, and fall back to the profile's first language.
    static func language(of text: String, in profile: LanguageProfile) -> SpeechLanguage {
        guard profile.isMixed else { return profile.primary }
        let recognizer = NLLanguageRecognizer()
        let candidates = profile.languages.map { NLLanguage(rawValue: $0.rawValue) }
        recognizer.languageConstraints = candidates
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage,
              let language = profile.languages.first(where: { $0.rawValue == dominant.rawValue })
        else { return profile.primary }
        return language
    }

    // MARK: - Result mapping

    private static let boundary: Character = "\u{2581}"

    /// SentencePiece pieces to words. A piece that starts with `▁` (or a
    /// space, as some FluidAudio paths normalize it) starts a word; every other
    /// piece, punctuation included, attaches to the word before it, which is
    /// how Whisper's words carry their punctuation too.
    ///
    /// A word's confidence is its least confident letter piece: one doubtful
    /// piece makes the whole word doubtful. Punctuation pieces do not count,
    /// so an unsure `?` cannot mark the word it follows.
    static func words(from tokens: [TokenTiming]) -> [Transcript.Word] {
        var words: [Transcript.Word] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidence: Double?

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(Transcript.Word(trimmed, start: start, end: end, confidence: confidence))
            }
            text = ""
            confidence = nil
        }

        for token in tokens {
            let piece = token.token
            let startsWord = piece.first == boundary || piece.first == " "
            let core = piece.replacingOccurrences(of: String(boundary), with: " ")
            if startsWord, !text.isEmpty, core.contains(where: { $0.isLetter || $0.isNumber }) {
                flush()
            }
            if text.isEmpty { start = token.startTime }
            text += core
            end = token.endTime
            if core.contains(where: { $0.isLetter || $0.isNumber }) {
                let value = Double(token.confidence)
                confidence = confidence.map { min($0, value) } ?? value
            }
        }
        flush()
        return words
    }

    // MARK: - Storage

    /// `Application Support/Witness/Models/fluidaudio/<variant>`. FluidAudio
    /// puts the repository folder next to the last component, so every
    /// variant lands in its own folder under `fluidaudio/`.
    static func modelDirectory(for variant: Variant) -> URL? {
        guard let base = WhisperKitTranscriptionService.modelDirectory() else { return nil }
        return base
            .appendingPathComponent("fluidaudio", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
    }
}
