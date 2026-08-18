import Foundation
import WhisperKit

/// Benchmark candidate: Whisper via WhisperKit (MIT, Argmax Inc.).
///
/// Dependency rationale, per `AGENTS.md`:
///
/// - Apple's `SFSpeechRecognizer` binds one recognizer to one locale and
///   reports a per-segment confidence that is routinely `0` on device. No
///   system framework at the macOS 14.4 deployment target returns per-word
///   probabilities, and Phase 3's risk engine cannot be built without them.
/// - `SpeechAnalyzer`/`SpeechTranscriber` would be the native answer, but it
///   requires macOS 26 and would cut off every user on macOS 14 and 15.
/// - WhisperKit is MIT-licensed, compatible with paid direct distribution,
///   runs entirely on-device through Core ML, covers all four MVP languages,
///   and returns `WordTiming.probability` per word.
///
/// Model weights are downloaded on an explicit user action into Application
/// Support, never into the app bundle. Nothing is uploaded: the download is a
/// one-way fetch of a static asset.
actor WhisperKitTranscriptionService: TranscriptionService {
    nonisolated let identifier = "whisperkit"
    nonisolated let displayName = "WhisperKit (Whisper large-v3 turbo)"

    /// Pinned to a multilingual variant on purpose. `recommendedModels()` can
    /// return a distil-whisper build, which is far weaker outside English and
    /// would quietly wreck German, Russian, and Ukrainian.
    private let modelVariant: String

    private var engine: WhisperKit?

    init(modelVariant: String = "openai_whisper-large-v3-v20240930_turbo") {
        self.modelVariant = modelVariant
    }

    /// Whisper is multilingual across every profile the MVP supports.
    nonisolated func supports(_ profile: LanguageProfile) -> Bool {
        profile.languages.allSatisfy { SpeechLanguage.allCases.contains($0) }
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        if engine != nil { return .ready }
        guard let folder = Self.modelDirectory() else {
            return .failed("Could not locate Application Support")
        }
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == false
        return installed
            ? .unavailable("Speech model is installed but not loaded yet")
            : .unavailable("The speech model has not been downloaded yet (about 600 MB)")
    }

    func prepare(for profile: LanguageProfile) async throws {
        guard engine == nil else { return }
        guard let downloadBase = Self.modelDirectory() else {
            throw TranscriptionError.modelUnavailable("Could not locate Application Support")
        }

        do {
            try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            let configuration = WhisperKitConfig(
                model: modelVariant,
                downloadBase: downloadBase,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            engine = try await WhisperKit(configuration)
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        guard !utterance.samples.isEmpty else { throw TranscriptionError.emptyAudio }
        guard utterance.sampleRate == AudioTargetFormat.sampleRate else {
            throw TranscriptionError.engineFailure(
                "Whisper expects 16 kHz audio, got \(Int(utterance.sampleRate)) Hz"
            )
        }

        if engine == nil {
            try await prepare(for: profile)
        }
        guard let engine else {
            throw TranscriptionError.modelUnavailable("The speech model is not loaded")
        }

        try Task.checkCancellation()
        let started = Date()

        let results: [TranscriptionResult]
        do {
            results = try await engine.transcribe(
                audioArray: utterance.samples,
                decodeOptions: Self.decodingOptions(for: profile)
            )
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }

        try Task.checkCancellation()
        let processingDuration = Date().timeIntervalSince(started)

        let segments = results.flatMap(\.segments)
        // Whisper reports ISO-639-1 codes, which are exactly our raw values.
        let detected = results.first.flatMap { SpeechLanguage(rawValue: $0.language) }

        return Transcript.assemble(
            words: Self.words(from: segments),
            profile: profile,
            detectedLanguage: detected ?? (profile.isMixed ? nil : profile.primary),
            audioDuration: utterance.duration,
            processingDuration: processingDuration,
            engineIdentifier: identifier
        )
    }

    // MARK: - Options

    private static func decodingOptions(for profile: LanguageProfile) -> DecodingOptions {
        // Whisper decodes one language per pass. A single-language profile pins
        // it; a mixed profile lets Whisper decide, which is the honest way to
        // serve DE+EN and RU+UK and is exactly what the benchmark must measure.
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: profile.isMixed ? nil : profile.primary.rawValue,
            detectLanguage: profile.isMixed,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
    }

    // MARK: - Result mapping

    private static func words(from segments: [TranscriptionSegment]) -> [Transcript.Word] {
        segments.flatMap { segment -> [Transcript.Word] in
            if let words = segment.words, !words.isEmpty {
                return words.compactMap { timing in
                    let text = timing.word.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    return Transcript.Word(
                        text,
                        start: TimeInterval(timing.start),
                        end: TimeInterval(timing.end),
                        confidence: Double(timing.probability)
                    )
                }
            }

            // Word timestamps can be unavailable for a segment. Falling back to
            // the segment's mean log probability keeps a confidence signal
            // rather than silently reporting none.
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return [] }
            return [
                Transcript.Word(
                    text,
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    confidence: Double(exp(segment.avgLogprob))
                )
            ]
        }
    }

    // MARK: - Storage

    /// Weights live in Application Support, outside the app bundle, so they
    /// survive updates and stay visible to the user.
    static func modelDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("LocalDictation/Models", isDirectory: true)
    }
}
