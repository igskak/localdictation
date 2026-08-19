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

    /// The one load in flight, shared by every caller.
    ///
    /// Actor isolation alone does not make loading single-flight. The actor is
    /// released at the `await` that builds `WhisperKit`, so a second caller
    /// sails past an `engine == nil` check and starts a second load of the same
    /// 1.5 GB model; the observed failure was six concurrent loads competing
    /// for one Neural Engine, none of them ever finishing. Holding the task —
    /// not just the finished result — is what makes later callers join the load
    /// that is already running.
    ///
    /// It carries `Void` rather than the engine because `WhisperKit` is not
    /// `Sendable`: the task assigns `engine` under this actor's isolation
    /// instead of handing the value across a boundary.
    private var loadTask: Task<Void, any Error>?

    /// What the in-flight load is doing, for `modelState`. Nil when idle.
    private var preparation: ModelPreparation?
    /// When the current load started, so a load that outruns
    /// `longLoadThreshold` can be reported as the one-time compilation it is.
    private var loadStartedAt: Date?

    /// Past this, a load is no longer "reading weights off disk". Measured on
    /// an M-series Mac: a warm load of large-v3-turbo is about 9 seconds, and a
    /// cold one — the first for this model on this OS build — is minutes.
    private static let longLoadThreshold: TimeInterval = 20

    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    init(modelVariant: String = "openai_whisper-large-v3-v20240930_turbo") {
        self.modelVariant = modelVariant
    }

    /// Whisper is multilingual across every profile the MVP supports.
    nonisolated func supports(_ profile: LanguageProfile) -> Bool {
        profile.languages.allSatisfy { SpeechLanguage.allCases.contains($0) }
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        if engine != nil { return .ready }

        // A load in flight has to be reported as such. Reporting "not loaded"
        // instead puts the "Prepare speech model…" button back in front of a
        // user who already pressed it, and every extra press used to start
        // another load.
        if let preparation {
            return .preparing(elapsedAdjusted(preparation))
        }
        // The task exists a moment before it has said what it is doing. Without
        // this the button would flash back for that moment.
        if loadTask != nil {
            return .preparing(ModelPreparation(phase: .loading))
        }

        guard Self.modelDirectory() != nil else {
            return .failed("Could not locate Application Support")
        }
        return Self.installedModelFolder(variant: modelVariant) != nil
            ? .unavailable("Speech model is installed but not loaded yet", needsUserAction: false)
            : .unavailable("The speech model has not been downloaded yet (about 600 MB)", needsUserAction: true)
    }

    /// Promotes a long-running load to the phase that explains itself. Nothing
    /// in Core ML says "I am compiling for the Neural Engine", but a load that
    /// has run for twenty seconds is not reading files off a disk.
    private func elapsedAdjusted(_ preparation: ModelPreparation) -> ModelPreparation {
        guard preparation.phase == .loading, let loadStartedAt else { return preparation }
        guard Date().timeIntervalSince(loadStartedAt) > Self.longLoadThreshold else { return preparation }
        return ModelPreparation(phase: .compilingForThisSystem)
    }

    func prepare(for profile: LanguageProfile) async throws {
        _ = try await loadedEngine()
    }

    /// The loaded engine, loading it once if nobody has yet.
    ///
    /// Every caller funnels through here, so the download and the Core ML
    /// compilation happen exactly once however many callers ask at once.
    private func loadedEngine() async throws -> WhisperKit {
        if let engine { return engine }

        let load: Task<Void, any Error>
        if let loadTask {
            // Someone else is already loading: wait for their result rather
            // than starting a competing load.
            load = loadTask
        } else {
            load = startLoad()
            loadTask = load
        }

        do {
            try await load.value
        } catch {
            // Cleared so a failure the user can act on — no disk space, no
            // network — can be retried from the button.
            if loadTask == load { loadTask = nil }
            throw error
        }

        guard let engine else {
            if loadTask == load { loadTask = nil }
            throw TranscriptionError.modelUnavailable("The speech model is not loaded")
        }
        return engine
    }

    /// Unstructured on purpose: an unstructured task does not inherit
    /// cancellation, so one superseded utterance cannot tear down a load that
    /// the rest of the app — and possibly the user's own Prepare press — is
    /// still waiting on.
    private func startLoad() -> Task<Void, any Error> {
        let variant = modelVariant
        return Task { [self] in
            defer {
                preparation = nil
                loadStartedAt = nil
            }
            guard let downloadBase = Self.modelDirectory() else {
                throw TranscriptionError.modelUnavailable("Could not locate Application Support")
            }
            do {
                // Download and load are separated so the download can report a
                // real percentage. Rolled into one `WhisperKit(_:)` call they
                // are one opaque wait, and the download — the phase that can
                // take the longest on a slow connection — is the one phase
                // where a number actually exists.
                let folder = try await modelFolder(variant: variant, downloadBase: downloadBase)

                preparation = ModelPreparation(phase: .loading)
                loadStartedAt = Date()
                let configuration = WhisperKitConfig(
                    model: variant,
                    downloadBase: downloadBase,
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    // The weights are already here. Passing the folder and
                    // refusing the download keeps this phase off the network.
                    download: false
                )
                // Assigned here, inside the actor, so every joiner sees the same
                // engine and the value never crosses an isolation boundary.
                engine = try await WhisperKit(configuration)
            } catch let error as TranscriptionError {
                throw error
            } catch {
                // Wrapped inside the task so joiners and the originating caller
                // receive the same error.
                throw TranscriptionError.modelUnavailable(error.localizedDescription)
            }
        }
    }

    /// The folder holding the weights, fetching them if this is the first run.
    private func modelFolder(variant: String, downloadBase: URL) async throws -> URL {
        if let installed = Self.installedModelFolder(variant: variant) {
            preparation = ModelPreparation(phase: .loading)
            return installed
        }

        preparation = ModelPreparation(phase: .downloading)
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        return try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            from: Self.modelRepo,
            progressCallback: { [weak self] progress in
                guard let self else { return }
                let fraction = progress.fractionCompleted
                Task { await self.report(downloadProgress: fraction) }
            }
        )
    }

    private func report(downloadProgress: Double) {
        guard preparation?.phase == .downloading else { return }
        preparation = ModelPreparation(phase: .downloading, progress: downloadProgress)
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        guard !utterance.samples.isEmpty else { throw TranscriptionError.emptyAudio }
        guard utterance.sampleRate == AudioTargetFormat.sampleRate else {
            throw TranscriptionError.engineFailure(
                "Whisper expects 16 kHz audio, got \(Int(utterance.sampleRate)) Hz"
            )
        }

        // Dictation never starts a download on its own: fetching the weights is
        // the app's only network access and stays bound to the explicit
        // "Prepare speech model…" action. Joining a load that action already
        // started is fine, and beats failing a recording the user just made.
        guard engine != nil || loadTask != nil else {
            throw TranscriptionError.modelUnavailable(
                "The speech model is not loaded. Use \u{201C}Prepare speech model\u{2026}\u{201D} first."
            )
        }
        let engine = try await loadedEngine()

        try Task.checkCancellation()
        let started = Date()

        var results = try await decode(
            utterance.samples,
            options: Self.decodingOptions(for: profile),
            using: engine
        )

        try Task.checkCancellation()

        // Whisper reports ISO-639-1 codes, which are exactly our raw values.
        var detected = results.first.flatMap { SpeechLanguage(rawValue: $0.language) }

        // Free detection chooses from every language Whisper knows, not from the
        // two the user selected, and it does wander: a Ukrainian utterance under
        // UK+EN came back decoded as Polish, in Latin script. Whisper names the
        // language it picked, so the miss is detectable exactly rather than by
        // guessing at the text.
        if profile.isMixed, detected == nil || !profile.contains(detected!) {
            let strayed = results.first?.language ?? "unknown"
            let pinned = try await languageWithinProfile(
                profile,
                samples: utterance.samples,
                using: engine
            )
            Log.transcription.notice(
                "Detected \(strayed, privacy: .public) outside profile \(profile.shortLabel, privacy: .public); redecoding as \(pinned.rawValue, privacy: .public)"
            )
            results = try await decode(
                utterance.samples,
                options: Self.decodingOptions(for: profile, pinnedTo: pinned),
                using: engine
            )
            detected = pinned
            try Task.checkCancellation()
        }

        let processingDuration = Date().timeIntervalSince(started)
        let segments = results.flatMap(\.segments)

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

    private func decode(
        _ samples: [Float],
        options: DecodingOptions,
        using engine: WhisperKit
    ) async throws -> [TranscriptionResult] {
        do {
            return try await engine.transcribe(audioArray: samples, decodeOptions: options)
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
    }

    /// The profile language Whisper considers most likely.
    ///
    /// Asks for the full language distribution and takes the best entry *within
    /// the profile*, rather than defaulting to the primary. A user who selected
    /// UK+EN and spoke English should not be re-decoded as Ukrainian just
    /// because the first pass strayed to a third language.
    ///
    /// Falls back to the primary when detection cannot be obtained at all —
    /// producing a transcript in a language the user selected beats failing the
    /// recording they just made.
    private func languageWithinProfile(
        _ profile: LanguageProfile,
        samples: [Float],
        using engine: WhisperKit
    ) async throws -> SpeechLanguage {
        // The WhisperKit method is spelled `detectLangauge`; the typo is theirs
        // and is part of the public API.
        guard let probabilities = try? await engine.detectLangauge(audioArray: samples).langProbs else {
            return profile.primary
        }
        return Self.bestLanguage(in: profile, probabilities: probabilities)
    }

    /// The profile language with the highest reported probability.
    ///
    /// Restricting the argmax to the profile is the whole point: Whisper's own
    /// ranking is trusted, but only among the languages the user actually
    /// selected. Falls back to the primary when no profile language appears in
    /// the distribution at all.
    static func bestLanguage(
        in profile: LanguageProfile,
        probabilities: [String: Float]
    ) -> SpeechLanguage {
        let ranked = profile.languages.compactMap { language -> (SpeechLanguage, Float)? in
            guard let probability = probabilities[language.rawValue] else { return nil }
            return (language, probability)
        }
        return ranked.max { $0.1 < $1.1 }?.0 ?? profile.primary
    }

    private static func decodingOptions(
        for profile: LanguageProfile,
        pinnedTo language: SpeechLanguage? = nil
    ) -> DecodingOptions {
        if let language {
            return DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language.rawValue,
                detectLanguage: false,
                skipSpecialTokens: true,
                wordTimestamps: true
            )
        }
        return baseDecodingOptions(for: profile)
    }

    private static func baseDecodingOptions(for profile: LanguageProfile) -> DecodingOptions {
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

    /// The folder holding this variant's weights, or nil when they are not on
    /// disk yet.
    ///
    /// Checks for the three model bundles rather than for a non-empty folder:
    /// an interrupted download leaves the folder populated but useless, and
    /// calling that "installed" sends the app down the offline path with
    /// nothing to load.
    static func installedModelFolder(variant: String) -> URL? {
        guard let base = modelDirectory() else { return nil }
        let folder = base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepo, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let present = required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return present ? folder : nil
    }

    /// Weights live in Application Support, outside the app bundle, so they
    /// survive updates and stay visible to the user.
    static func modelDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("LocalDictation/Models", isDirectory: true)
    }
}
