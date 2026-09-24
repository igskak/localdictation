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

    /// The language the last utterance was decoded as, and when.
    ///
    /// Read by `LanguageDecision` when a distribution is too close to call, and
    /// deliberately kept here rather than in the coordinator: it is a property
    /// of a conversation with the engine, it expires, and nothing outside this
    /// actor should be able to set it.
    private var lastDecodedLanguage: (language: SpeechLanguage, at: Date)?

    /// The language distribution being computed for an utterance that is still
    /// being spoken, together with the audio it is being computed from.
    ///
    /// It carries probabilities rather than a decided language on purpose. The
    /// expensive half — mel plus a full encoder pass — is what has to run early;
    /// the rule that turns a distribution into one language is arithmetic, and
    /// it depends on what the user was speaking a moment ago and on which
    /// languages they currently have selected. Both are properties of the
    /// moment the utterance ends, not of the moment the head start began.
    private var headStart: (prefix: [Float], task: Task<[String: Float]?, Never>)?

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

    /// Whisper is multilingual across every language this app can name.
    ///
    /// `SpeechLanguage` is closed over `LanguageCatalog`, which is Whisper's own
    /// language list, so there is no profile this engine cannot be asked for.
    /// The method stays because the protocol has engines that cannot say the
    /// same — `AppleSpeechTranscriptionService` binds one recognizer to one
    /// locale and depends on what macOS has installed.
    nonisolated func supports(_ profile: LanguageProfile) -> Bool {
        true
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        if engine != nil { return .ready }

        // A load in flight has to be reported as such. Reporting "not loaded"
        // instead puts the fetch button back in front of a user who is already
        // waiting on one, and every extra press used to start another load.
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

    // MARK: - Language head start

    /// Spelled `async` to match the protocol requirement exactly. A synchronous
    /// method on an actor is callable the same way from outside, but it is a
    /// *different* overload from the one the protocol declares, and the empty
    /// default in `extension TranscriptionService` wins the resolution — which
    /// is how this silently did nothing at all while every test passed.
    func beginLanguageDetection(prefix: [Float], profile: LanguageProfile) async {
        // A single selected language never reaches the detector at all, so
        // there is nothing to run ahead of.
        guard profile.isMixed else { return }
        guard prefix.count >= LanguageHeadStart.frames else { return }
        if let existing = headStart {
            // One call arrives per press, so a different opening means a
            // different recording and this one supersedes it. Left to expire on
            // its own, a head start from a recording that was abandoned before
            // it could be transcribed would refuse the next one and cost the
            // following utterance its own.
            guard existing.prefix != prefix else { return }
            existing.task.cancel()
        }
        // Deliberately does not load. `loadedEngine()` would start a 600 MB
        // download or a minutes-long compilation from inside a recording, and
        // the head start is an optimization: absent an engine it simply does
        // not happen and `transcribe` decides the language the way it always
        // did.
        guard engine != nil else { return }

        // `[self]` rather than the engine, for the same reason `startLoad` does
        // it: the task then runs under this actor's isolation and the
        // non-`Sendable` `WhisperKit` never crosses a boundary. What comes back
        // out is a plain dictionary.
        headStart = (prefix, Task { [self] in
            guard let engine else { return nil }
            return try? await engine.detectLangauge(audioArray: prefix).langProbs
        })
    }

    /// The distribution computed while this utterance was being spoken, if the
    /// head start was for this utterance and it produced one.
    ///
    /// Matched by the audio itself rather than by a token or a lifecycle call.
    /// A recording that is abandoned, superseded, or interrupted leaves a head
    /// start behind, and the only thing that makes it impossible to spend that
    /// answer on somebody else's sentence is checking that this sentence
    /// literally begins with the audio it was computed from.
    private func headStartProbabilities(for samples: [Float]) async -> [String: Float]? {
        guard let headStart else { return nil }
        self.headStart = nil
        guard samples.count >= headStart.prefix.count, samples.starts(with: headStart.prefix) else {
            headStart.task.cancel()
            return nil
        }
        return await headStart.task.value
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

        // Dictation never starts a download from inside a recording. The fetch
        // belongs to launch and to the menu, where it can report progress and
        // be waited for; starting one here would tie a 600 MB download to a
        // recording the user expects back in seconds. Joining a load that is
        // already running is fine, and beats failing a recording they just
        // made — and since the coordinator answers a press the model is not
        // ready for, reaching this at all now means a load that ended between
        // the press and the transcription.
        guard engine != nil || loadTask != nil else {
            throw TranscriptionError.modelUnavailable("The speech model is not loaded yet.")
        }
        let engine = try await loadedEngine()

        try Task.checkCancellation()
        let started = Date()

        // Decided before the decode rather than corrected after one. The old
        // path decoded with free detection, noticed afterwards when Whisper had
        // wandered outside the profile — a Ukrainian utterance came back as
        // Polish, in Latin script — and then detected and decoded a second
        // time. Pinning what the ranking says makes that miss unreachable
        // instead of recoverable, and costs one decode rather than two.
        let selection = try await decodedLanguage(for: profile, samples: utterance.samples, using: engine)
        let language = selection.language
        let languageReadyAt = Date()

        try Task.checkCancellation()

        let results = try await decode(
            utterance.samples,
            options: Self.decodingOptions(pinnedTo: language),
            using: engine
        )
        let decodedAt = Date()

        try Task.checkCancellation()
        lastDecodedLanguage = (language, Date())

        // Local timing only: these two durations reveal whether language
        // selection or decoding dominates, without recording any speech data.
        // The marker says whether the language stage was paid on this wait or
        // while the user was still speaking, which is the difference the head
        // start exists to make and the only way to see it in one line.
        Log.transcription.info(
            "Inference stages: language \(String(format: "%.2f", languageReadyAt.timeIntervalSince(started)), privacy: .public) s \(selection.source.rawValue, privacy: .public), decode \(String(format: "%.2f", decodedAt.timeIntervalSince(languageReadyAt)), privacy: .public) s"
        )

        let processingDuration = Date().timeIntervalSince(started)
        let segments = results.flatMap(\.segments)

        return Transcript.assemble(
            words: Self.words(from: segments),
            profile: profile,
            detectedLanguage: language,
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

    /// The language this utterance will be decoded as, and what it cost to
    /// arrive at. Only the log reads the source: it is the one line that says
    /// whether the language stage was paid on the user's wait.
    private struct LanguageSelection {
        enum Source: String {
            /// One language selected, so nothing was detected at all.
            case singleLanguage = "(single)"
            /// Decided while the user was still speaking.
            case headStart = "(ahead)"
            /// Too short to detect; carried over from the previous utterance.
            case carriedOver = "(carried)"
            /// Detected after the recording ended, on the wait.
            case detectedOnTheWait = "(on the wait)"
        }

        let language: SpeechLanguage
        let source: Source
    }

    /// Which of the user's languages to decode this utterance as.
    ///
    /// A single-language profile never reaches the engine's detector at all,
    /// which is both correct and the cheaper path. Everything else wants the
    /// full distribution, and there are three ways to have one, in descending
    /// order of what they cost the user:
    ///
    /// 1. The head start ran while they were still speaking. Free.
    /// 2. The utterance was too short to have had one. A couple of words carry
    ///    almost no evidence anyway, so what they were speaking a moment ago is
    ///    a better answer than a full encoder pass over a word and a half.
    /// 3. Neither. The detector runs here, on the wait, as it always did.
    ///
    /// Falls back to the recent language and then to the preferred one when the
    /// detector cannot be reached — producing a transcript in a language the
    /// user selected beats failing the recording they just made.
    private func decodedLanguage(
        for profile: LanguageProfile,
        samples: [Float],
        using engine: WhisperKit
    ) async throws -> LanguageSelection {
        guard profile.isMixed else {
            return LanguageSelection(language: profile.primary, source: .singleLanguage)
        }

        var source = LanguageSelection.Source.headStart
        var probabilities = await headStartProbabilities(for: samples)

        if probabilities == nil, samples.count < LanguageHeadStart.frames,
           let recent = recentLanguage(in: profile) {
            let decision = LanguageDecision(language: recent, reason: .carriedOverFromPrevious)
            log(decision, for: profile)
            return LanguageSelection(language: decision.language, source: .carriedOver)
        }

        if probabilities == nil {
            source = .detectedOnTheWait
            // The WhisperKit method is spelled `detectLangauge`; the typo is
            // theirs and is part of the public API.
            probabilities = try? await engine.detectLangauge(audioArray: samples).langProbs
        }

        guard let probabilities else {
            let fallback = recentLanguage(in: profile) ?? profile.primary
            Log.transcription.notice(
                "Language detection unavailable; decoding \(profile.shortLabel, privacy: .public) as \(fallback.rawValue, privacy: .public)"
            )
            return LanguageSelection(language: fallback, source: source)
        }

        let decision = LanguageDecision.choose(
            profile: profile,
            probabilities: probabilities,
            previous: recentLanguage(in: profile)
        )
        log(decision, for: profile)
        return LanguageSelection(language: decision.language, source: source)
    }

    /// Logged for every mixed utterance, because "why is this Russian" is a
    /// question the user will ask and the answer is a rule, not a mood.
    private func log(_ decision: LanguageDecision, for profile: LanguageProfile) {
        Log.transcription.info(
            "\(profile.shortLabel, privacy: .public) decoded as \(decision.language.rawValue, privacy: .public) (\(decision.reason.rawValue, privacy: .public))"
        )
    }

    /// The last decoded language, while it is still worth knowing.
    ///
    /// Expires, and is dropped when the user has since deselected it: a
    /// language they no longer speak has no vote in what they are speaking now.
    private func recentLanguage(in profile: LanguageProfile) -> SpeechLanguage? {
        guard let last = lastDecodedLanguage else { return nil }
        guard Date().timeIntervalSince(last.at) <= LanguageDecision.recencyWindow else { return nil }
        guard profile.contains(last.language) else { return nil }
        return last.language
    }

    /// The profile language the engine ranks highest, for the benchmark and for
    /// tests that assert the clamp without going near a decode.
    static func bestLanguage(
        in profile: LanguageProfile,
        probabilities: [String: Float]
    ) -> SpeechLanguage {
        LanguageDecision.choose(profile: profile, probabilities: probabilities).language
    }

    /// Whisper decodes one language per pass, and since Phase 7 that language
    /// is always decided in advance.
    private static func decodingOptions(pinnedTo language: SpeechLanguage) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.rawValue,
            detectLanguage: false,
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
        ApplicationSupportDirectory.subdirectory("Models")
    }
}
