import CoreML
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
    /// Who an inference is for. Dictation and the Notetaker share one loaded
    /// model, but not a conversation: each keeps its own recent language, and
    /// only dictation writes the per-utterance timing line.
    enum Caller: Hashable, Sendable {
        case dictation
        case meeting
    }

    nonisolated var identifier: String {
        modelVariant == Self.defaultModelVariant ? "whisperkit" : "whisperkit-large-v3"
    }
    nonisolated var displayName: String {
        modelVariant == Self.defaultModelVariant
            ? "Whisper large-v3 turbo" : "Whisper large-v3 (full)"
    }

    /// Pinned to a multilingual variant on purpose. `recommendedModels()` can
    /// return a distil-whisper build, which is far weaker outside English and
    /// would quietly wreck German, Russian, and Ukrainian.
    private let modelVariant: String
    private let logsInference: Bool

    private var engine: WhisperKit?

    /// The encoder WhisperKit is built with when the second pass over the
    /// first window is skipped. See `EncoderOutputReuse` for why this cannot
    /// change what the language detector or the decoder see. Nil runs
    /// WhisperKit's own encoder, which the parity check compares against.
    private let encoder: ReusingAudioEncoder?

    /// When the previous inference finished, so the log can say how long the
    /// engine sat idle before this one. A first press after a long pause
    /// looks slower than a warm one, and without this the two cannot be told
    /// apart in a log.
    private var lastInferenceEndedAt: Date?

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
    ///
    /// Kept per caller: a meeting held in English has no vote in what the
    /// user dictates next, and a dictation has none in the meeting.
    private var lastDecodedLanguage: [Caller: (language: SpeechLanguage, at: Date)] = [:]

    /// The languages of the current meeting's confident windows, newest last.
    /// A meeting runs for an hour, so one previous window is too little to
    /// hold its language against a stray detection; see
    /// `LanguageDecision.prevailing`. Forgotten after `recencyWindow` without a
    /// meeting window, which ends it.
    private var meetingLanguages: [SpeechLanguage] = []
    private var meetingLanguageAt: Date?
    private static let meetingLanguageMemory = 30

    /// One inference on the model at a time, in arrival order.
    ///
    /// The actor is released at every `await` inside an inference, so without
    /// this a dictation and a meeting window would run on one `WhisperKit` at
    /// once and interleave `EncoderOutputReuse`'s per-utterance state. The
    /// Neural Engine runs them one after another anyway; the queue only makes
    /// the order explicit.
    private var inferenceTurns = InferenceTurns<CheckedContinuation<Void, Never>>()

    /// What the in-flight load is doing, for `modelState`. Nil when idle.
    private var preparation: ModelPreparation?
    /// Measures the download in flight. Nil whenever there is none, and also
    /// when the total could not be learned: a bar with an invented total is
    /// worse than the spinner it replaces.
    private var meter: ModelDownloadMeter?
    /// When the current load started, so a load that outruns
    /// `longLoadThreshold` can be reported as the one-time compilation it is.
    private var loadStartedAt: Date?

    /// Past this, a load is no longer "reading weights off disk". Measured on
    /// an M-series Mac: a warm load of large-v3-turbo is about 9 seconds, and a
    /// cold one — the first for this model on this OS build — is minutes.
    private static let longLoadThreshold: TimeInterval = 20

    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// WhisperKit defaults to five full retries at rising temperatures. In a
    /// real eight-second dictation that returned no words, those retries spent
    /// 5.47 seconds after language selection and still ended empty. One retry
    /// preserves a conservative recovery attempt without making weak input run
    /// through four more increasingly hallucinatory decodes.
    static let maximumTemperatureFallbacks = 1

    /// The variant this app ships against, and the one
    /// `SpeechModelDownloadSize.pinnedVariantBytes` was measured for.
    static let defaultModelVariant = "openai_whisper-large-v3-v20240930_turbo"

    /// Text Whisper is conditioned on before each utterance, per language.
    ///
    /// Whisper continues the style of its previous text, punctuation density
    /// included, so a short punctuated passage with a question in it is the
    /// cheapest lever on how often it writes `?`. Empty in the shipped app:
    /// it stays a benchmark knob until the punctuation corpus says it helps
    /// without making Whisper echo the prompt into silence.
    private let decodingPrompts: [SpeechLanguage: String]

    init(
        modelVariant: String = WhisperKitTranscriptionService.defaultModelVariant,
        reusesEncoderOutput: Bool = true,
        logsInference: Bool = true,
        decodingPrompts: [SpeechLanguage: String] = [:]
    ) {
        self.modelVariant = modelVariant
        self.logsInference = logsInference
        self.decodingPrompts = decodingPrompts
        encoder = reusesEncoderOutput ? ReusingAudioEncoder() : nil
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
            return .preparing(measured(preparation))
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
            : .unavailable(
                modelVariant == Self.defaultModelVariant
                    ? L10n.format("The speech model has not been downloaded yet (about %@)", SpeechModelDownloadSize.pinnedVariantSizeText)
                    : "The selected Whisper model has not been downloaded yet (about 3.2 GB)",
                needsUserAction: true
            )
    }

    /// Fills in what only the disk and the clock can say, which is everything
    /// the user reads while they wait: how far a download has got, and whether a
    /// load has been running long enough to be a compilation.
    ///
    /// It belongs here rather than in the download's own callback because a
    /// stalled transfer produces no callbacks at all, and a bar whose last
    /// estimate was taken before the stall goes on promising four minutes. The
    /// menu asks for this state every 400 ms; the meter samples the disk twice a
    /// second and answers the rest from what it already measured.
    private func measured(_ preparation: ModelPreparation) -> ModelPreparation {
        guard preparation.phase == .downloading else { return elapsedAdjusted(preparation) }
        guard let progress = meter?.progress() else { return preparation }
        return ModelPreparation(phase: .downloading, download: progress)
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
                    audioEncoder: encoder,
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
                // receive the same error — and classified here, where the real
                // `URLError` or `ENOSPC` is still in hand. One line further up
                // the stack there is only a localized sentence, and reading a
                // cause out of a sentence is how a funnel starts lying.
                throw TranscriptionError.modelPreparationFailed(
                    ModelPreparationFailure(error),
                    detail: error.localizedDescription
                )
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
        meter = await Self.makeMeter(variant: variant, downloadBase: downloadBase)
        defer { meter = nil }
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

    /// A meter for this variant, or nil when there is no total to measure
    /// against.
    ///
    /// The size is asked for before the transfer starts rather than derived from
    /// it: WhisperKit's own progress counts files, and this model is one 1.27 GB
    /// file among twenty-three small ones, so its fraction says almost nothing
    /// about the bytes. The request is short and its failure costs only the
    /// numbers, never the download.
    private static func makeMeter(variant: String, downloadBase: URL) async -> ModelDownloadMeter? {
        let listed = await SpeechModelDownloadSize.bytes(repo: modelRepo, variant: variant)
        // The measured constant stands in only for the variant it was measured
        // for. Any other variant gets no bar rather than the wrong one.
        let total = listed ?? (variant == defaultModelVariant ? SpeechModelDownloadSize.pinnedVariantBytes : nil)
        guard let total, total > 0 else {
            Log.transcription.info("Downloading the speech model without a total: no size to measure against")
            return nil
        }
        Log.transcription.info(
            "Speech model download: \(total, privacy: .public) bytes expected, \(listed == nil ? "measured constant" : "listed by the repository", privacy: .public)"
        )
        return ModelDownloadMeter(totalBytes: total) {
            downloadedByteCount(variant: variant, downloadBase: downloadBase)
        }
    }

    /// Internal rather than private so `ModelDownloadMeterTests` can hold the one
    /// assumption in here that no unit test can derive: that these are the paths
    /// WhisperKit's downloader actually writes into.
    static func downloadedByteCount(variant: String, downloadBase: URL) -> Int64 {
        downloadFolders(variant: variant, downloadBase: downloadBase).reduce(0) { $0 + byteCount(of: $1) }
    }

    /// The two places this variant's bytes land: the model folder, for the files
    /// that have arrived, and the Hub's own download cache, for the one still
    /// being written into a `.incomplete` file. Counted per variant rather than
    /// per repository, so weights for another variant on the same Mac cannot
    /// fill the bar.
    ///
    /// Matched the way WhisperKit matches them, by suffix: its glob is
    /// `*<variant>/*`, so a short variant name can legitimately resolve to a
    /// longer folder. Assuming the folder is named exactly what was asked for
    /// would leave the bar at 0% for a whole download in that case, which is
    /// worse than the spinner it replaced.
    private static func downloadFolders(variant: String, downloadBase: URL) -> [URL] {
        let repoFolder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepo, isDirectory: true)
        let parents = [
            repoFolder,
            repoFolder
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("download", isDirectory: true)
        ]
        return parents
            .flatMap { parent in
                (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            }
            .filter { $0.lastPathComponent.hasSuffix(variant) }
    }

    private static func byteCount(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    /// WhisperKit's own count of finished files, which is only read when there is
    /// no meter: with one, `measured` answers from the bytes instead.
    private func report(downloadProgress: Double) {
        guard preparation?.phase == .downloading, meter == nil else { return }
        preparation = ModelPreparation(phase: .downloading, progress: downloadProgress)
    }

    /// A view of this engine for the Notetaker: the same loaded model, its own
    /// recent language, no timing line.
    ///
    /// The meeting used to build a second engine of its own. That held the
    /// 1.27 GB encoder twice and, whenever macOS had evicted its Neural Engine
    /// compilation, made the user wait minutes for a model dictation already
    /// had in memory.
    nonisolated var meetingClient: WhisperKitMeetingClient {
        WhisperKitMeetingClient(service: self)
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        try await transcribe(utterance, profile: profile, caller: .dictation)
    }

    func transcribe(
        _ utterance: CapturedUtterance,
        profile: LanguageProfile,
        caller: Caller
    ) async throws -> Transcript {
        guard !utterance.samples.isEmpty else { throw TranscriptionError.emptyAudio }
        guard utterance.sampleRate == AudioTargetFormat.sampleRate else {
            throw TranscriptionError.engineFailure(
                "Whisper expects 16 kHz audio, got \(Int(utterance.sampleRate)) Hz"
            )
        }

        // Dictation never starts a download from inside a recording. The fetch
        // belongs to launch and to the menu, where it can report progress and
        // be waited for; starting one here would tie a 1.6 GB download to a
        // recording the user expects back in seconds. Joining a load that is
        // already running is fine, and beats failing a recording they just
        // made — and since the coordinator answers a press the model is not
        // ready for, reaching this at all now means a load that ended between
        // the press and the transcription.
        guard engine != nil || loadTask != nil else {
            throw TranscriptionError.modelUnavailable("The speech model is not loaded yet.")
        }
        let engine = try await loadedEngine()

        let queuedAt = Date()
        await beginInference()
        defer { endInference() }
        try Task.checkCancellation()
        let started = Date()
        let queued = started.timeIntervalSince(queuedAt)
        let idle = lastInferenceEndedAt.map { started.timeIntervalSince($0) }
        defer { lastInferenceEndedAt = Date() }
        let logs = logsInference && caller == .dictation

        // Only a mixed profile encodes the first window twice: once for the
        // language, once in the decode. A single language never asks for the
        // language, so there is nothing to remember and nothing is held.
        if profile.isMixed { encoder?.reuse.beginUtterance() }
        defer { encoder?.reuse.endUtterance() }

        // Decided before the decode rather than corrected after one. The old
        // path decoded with free detection, noticed afterwards when Whisper had
        // wandered outside the profile — a Ukrainian utterance came back as
        // Polish, in Latin script — and then detected and decoded a second
        // time. Pinning what the ranking says makes that miss unreachable
        // instead of recoverable, and costs one decode rather than two.
        let language = try await decodedLanguage(for: profile, caller: caller, logs: logs, samples: utterance.samples, using: engine)
        let languageReadyAt = Date()

        try Task.checkCancellation()

        let results = try await decode(
            utterance.samples,
            options: Self.decodingOptions(
                pinnedTo: language,
                promptTokens: promptTokens(for: language, using: engine)
            ),
            using: engine
        )
        let decodedAt = Date()
        let reusedPasses = encoder?.reuse.endUtterance() ?? 0
        let fallbacks = results.reduce(0) { $0 + Int($1.timings.totalDecodingFallbacks) }
        let segments = results.flatMap(\.segments)
        let maximumNoSpeechProbability = segments.map(\.noSpeechProb).max()

        try Task.checkCancellation()
        lastDecodedLanguage[caller] = (language, Date())

        // Local timing only: counts and durations, no speech data. The two
        // durations say whether language selection or decoding dominates;
        // `reused` says whether the decode was spared its encoder pass;
        // `fallbacks` counts the decodes WhisperKit silently repeated at a
        // higher temperature, which is what makes the same phrase take one
        // second once and four the next; `idle` separates a cold first press
        // from a warm one.
        if logs {
            Log.transcription.info(
                "Inference stages: queued \(String(format: "%.2f", queued), privacy: .public) s, language \(String(format: "%.2f", languageReadyAt.timeIntervalSince(started)), privacy: .public) s, decode \(String(format: "%.2f", decodedAt.timeIntervalSince(languageReadyAt)), privacy: .public) s, encoder passes reused \(reusedPasses, privacy: .public), fallbacks \(fallbacks, privacy: .public)/\(Self.maximumTemperatureFallbacks, privacy: .public), segments \(segments.count, privacy: .public), max no-speech \(maximumNoSpeechProbability.map { String(format: "%.3f", $0) } ?? "unavailable", privacy: .public), idle \(idle.map { String(format: "%.0f s", $0) } ?? "first", privacy: .public)"
            )
        }

        let processingDuration = Date().timeIntervalSince(started)

        var transcript = Transcript.assemble(
            words: Self.words(from: segments),
            profile: profile,
            detectedLanguage: language,
            audioDuration: utterance.duration,
            processingDuration: processingDuration,
            engineIdentifier: identifier
        )
        transcript.maximumNoSpeechProbability = maximumNoSpeechProbability.map(Double.init)
        return transcript
    }

    private func beginInference() async {
        guard !inferenceTurns.enter() else { return }
        await withCheckedContinuation { inferenceTurns.wait($0) }
    }

    private func endInference() {
        inferenceTurns.leave()?.resume()
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

    /// Which of the user's languages to decode this utterance as.
    ///
    /// A single-language profile never reaches the engine's detector at all,
    /// which is both correct and the cheaper path. Everything else asks for the
    /// full distribution once and hands it, the profile, and the previous
    /// utterance's language to `LanguageDecision`.
    ///
    /// Falls back to the recent language and then to the preferred one when the
    /// detector cannot be reached — producing a transcript in a language the
    /// user selected beats failing the recording they just made.
    private func decodedLanguage(
        for profile: LanguageProfile,
        caller: Caller,
        logs: Bool,
        samples: [Float],
        using engine: WhisperKit
    ) async throws -> SpeechLanguage {
        guard profile.isMixed else { return profile.primary }

        // Not `engine.detectLangauge`: see `languageDistribution`.
        guard let probabilities = try? await engine.languageDistribution(audioArray: samples) else {
            let fallback = recentLanguage(in: profile, caller: caller) ?? profile.primary
            if logs {
                Log.transcription.notice(
                    "Language detection unavailable; decoding \(profile.shortLabel, privacy: .public) as \(fallback.rawValue, privacy: .public)"
                )
            }
            return fallback
        }

        let decision: LanguageDecision
        switch caller {
        case .dictation:
            decision = LanguageDecision.choose(
                profile: profile,
                probabilities: probabilities,
                previous: recentLanguage(in: profile, caller: caller)
            )
        case .meeting:
            decision = meetingLanguage(profile: profile, probabilities: probabilities)
        }
        // Logged for every mixed utterance, because "why is this Russian" is a
        // question the user will ask and the answer is a rule, not a mood.
        // The two leading probabilities ride along, numbers and codes only, so
        // a doubtful decision can be read back rather than guessed at.
        if logs {
            let leaders = Self.leaders(profile: profile, probabilities: probabilities)
            Log.transcription.info(
                "\(profile.shortLabel, privacy: .public) decoded as \(decision.language.rawValue, privacy: .public) (\(decision.reason.rawValue, privacy: .public)); leaders \(leaders, privacy: .public)"
            )
        }
        return decision.language
    }

    private func meetingLanguage(profile: LanguageProfile, probabilities: [String: Float]) -> LanguageDecision {
        let now = Date()
        if let meetingLanguageAt, now.timeIntervalSince(meetingLanguageAt) > LanguageDecision.recencyWindow {
            meetingLanguages = []
        }
        meetingLanguageAt = now
        let prevailing = LanguageDecision.prevailing(in: meetingLanguages, profile: profile)
        let decision = LanguageDecision.choose(
            profile: profile,
            probabilities: probabilities,
            previous: prevailing ?? recentLanguage(in: profile, caller: .meeting),
            // Wider only once the meeting has a language to hold. Before that
            // a wider margin would hand more windows to the preferred
            // language, which is no evidence about this call at all.
            margin: prevailing == nil ? LanguageDecision.defaultMargin : LanguageDecision.meetingMargin
        )
        if decision.reason == .confident {
            meetingLanguages.append(decision.language)
            meetingLanguages = Array(meetingLanguages.suffix(Self.meetingLanguageMemory))
        }
        // Numbers and language codes only, never words: what the margin needs
        // to be tuned from recordings.
        let ranked = Self.leaders(profile: profile, probabilities: probabilities)
        Log.transcription.notice(
            "Meeting language \(decision.language.rawValue, privacy: .public) (\(decision.reason.rawValue, privacy: .public)); leaders \(ranked, privacy: .public); prevailing \(prevailing?.rawValue ?? "none", privacy: .public)"
        )
        return decision
    }

    /// The two selected languages the engine ranks highest, as the log prints
    /// them: "uk 0.71, ru 0.24".
    private static func leaders(profile: LanguageProfile, probabilities: [String: Float]) -> String {
        LanguageDecision.rank(profile: profile, probabilities: probabilities).prefix(2)
            .map { "\($0.language.rawValue) \(String(format: "%.2f", $0.probability))" }
            .joined(separator: ", ")
    }

    /// The last decoded language, while it is still worth knowing.
    ///
    /// Expires, and is dropped when the user has since deselected it: a
    /// language they no longer speak has no vote in what they are speaking now.
    private func recentLanguage(in profile: LanguageProfile, caller: Caller) -> SpeechLanguage? {
        guard let last = lastDecodedLanguage[caller] else { return nil }
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
    static func decodingOptions(pinnedTo language: SpeechLanguage, promptTokens: [Int]? = nil) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.rawValue,
            temperatureFallbackCount: maximumTemperatureFallbacks,
            detectLanguage: false,
            skipSpecialTokens: true,
            wordTimestamps: true,
            promptTokens: promptTokens
        )
    }

    /// The configured prompt as decoder tokens, or nil when this language has
    /// none. Special tokens are filtered here as well as in WhisperKit, so a
    /// prompt can never smuggle in a language or task token.
    private func promptTokens(for language: SpeechLanguage, using engine: WhisperKit) -> [Int]? {
        guard let prompt = decodingPrompts[language], let tokenizer = engine.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Result mapping

    static func words(from segments: [TranscriptionSegment]) -> [Transcript.Word] {
        var result: [Transcript.Word] = []
        for segment in segments {
            let hasEarlierSegment = !result.isEmpty
            if let words = segment.words, !words.isEmpty {
                var isFirstWord = true
                for timing in words {
                    let text = timing.word.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    result.append(Transcript.Word(
                        text, start: TimeInterval(timing.start), end: TimeInterval(timing.end),
                        confidence: Double(timing.probability),
                        segmentBoundaryBefore: hasEarlierSegment && isFirstWord
                    ))
                    isFirstWord = false
                }
                continue
            }
            // A segment without word timing still contributes its text and
            // segment-level confidence, as in the original adapter.
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            result.append(Transcript.Word(
                text, start: TimeInterval(segment.start), end: TimeInterval(segment.end),
                confidence: Double(exp(segment.avgLogprob)), segmentBoundaryBefore: hasEarlierSegment
            ))
        }
        return result
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

extension WhisperKit {
    /// Whisper's language detection with the whole distribution kept.
    ///
    /// WhisperKit 1.1's own `detectLangauge` returns `langProbs` with exactly
    /// one entry: the language its greedy sampler picked over all hundred,
    /// with that pick's log-probability. `LanguageDecision` was written for a
    /// distribution, so with one entry every in-profile pick was "confident",
    /// and the margin, the previous utterance and the meeting's prevailing
    /// language never had a say. On 05.11 a Ukrainian call had 32 windows
    /// decided as English at log-probabilities down to -1.4, about 25%, and
    /// two of them came out as English translations of Ukrainian speech.
    ///
    /// This runs the same steps as `detectLangauge`, in the same order and
    /// with the same window, so the encoder input is byte for byte what the
    /// decode builds and `EncoderOutputReuse` still spares the second pass.
    /// The only difference is a sampler that keeps the logits of every
    /// language token before WhisperKit's greedy pick.
    ///
    /// Runs on the caller's actor, like the WhisperKit call it replaces, so the
    /// engine never leaves the transcription service's isolation.
    nonisolated(nonsending) func languageDistribution(audioArray: [Float]) async throws -> [String: Float] {
        guard textDecoder.isModelMultilingual, let tokenizer else {
            throw TranscriptionError.engineFailure("Language detection needs a multilingual model")
        }
        let options = DecodingOptions(verbose: false)
        let decoderInputs = try textDecoder.prepareDecoderInputs(
            withPrompt: [tokenizer.specialTokens.startOfTranscriptToken]
        )
        guard
            let window = audioProcessor.padOrTrim(
                fromArray: audioArray,
                startAt: 0,
                toLength: featureExtractor.windowSamples ?? Constants.defaultWindowSamples
            ),
            let mel = try await featureExtractor.logMelSpectrogram(fromAudio: window),
            let encoded = try await audioEncoder.encodeFeatures(mel)
        else {
            throw TranscriptionError.engineFailure("Language detection produced no encoder output")
        }

        var languages: [Int: String] = [:]
        for token in tokenizer.allLanguageTokens {
            languages[token] = tokenizer.decode(tokens: [token]).trimmingSpecialTokenCharacters()
        }
        let capture = LanguageLogitCapture(
            base: GreedyTokenSampler(
                temperature: 0,
                eotToken: tokenizer.specialTokens.endToken,
                decodingOptions: options
            ),
            languages: languages
        )
        _ = try await textDecoder.detectLanguage(
            from: encoded,
            using: decoderInputs,
            sampler: capture,
            options: options,
            temperature: 0
        )
        let distribution = LanguageDecision.distribution(fromLogits: capture.logits)
        guard !distribution.isEmpty else {
            throw TranscriptionError.engineFailure("Language detection produced no language scores")
        }
        return distribution
    }
}

/// Keeps the decoder's score for every language token, then lets WhisperKit's
/// own greedy sampler pick exactly as it would have.
///
/// WhisperKit's language filter has already set every other token to minus
/// infinity by the time the sampler sees the logits; the language tokens are
/// left as the model produced them.
private final class LanguageLogitCapture: TokenSampling {
    private let base: GreedyTokenSampler
    private let languages: [Int: String]
    private(set) var logits: [String: Float] = [:]

    init(base: GreedyTokenSampler, languages: [Int: String]) {
        self.base = base
        self.languages = languages
    }

    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        if self.logits.isEmpty, let vocabulary = logits.shape.last?.intValue {
            var captured: [String: Float] = [:]
            for (token, code) in languages where token < vocabulary {
                captured[code] = logits[[0, 0, NSNumber(value: token)]].floatValue
            }
            self.logits = captured
        }
        return await base.update(tokens: tokens, logits: logits, logProbs: logProbs)
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        base.finalize(tokens: tokens, logProbs: logProbs)
    }
}

/// WhisperKit's side of `EncoderOutputReuse`.
///
/// Built by composition because WhisperKit's `AudioEncoder` is `public`
/// rather than `open`. Loading goes through `WhisperMLModel`'s own default
/// implementation, which assigns `model`; forwarding that property is what
/// puts the loaded weights into the real encoder underneath, so the compute
/// units, the prewarm and the Neural Engine compilation are exactly
/// WhisperKit's.
private final class ReusingAudioEncoder: AudioEncoding, WhisperMLModel, @unchecked Sendable {
    let reuse = EncoderOutputReuse()
    private let base = AudioEncoder()

    var model: MLModel? {
        get { base.model }
        set { base.model = newValue }
    }

    var embedSize: Int? { base.embedSize }

    func encodeFeatures(_ features: any FeatureExtractorOutputType) async throws -> (any AudioEncoderOutputType)? {
        guard let mel = features as? MLMultiArray else {
            return try await base.encodeFeatures(features)
        }
        if let reused = reuse.reusedOutput(for: mel) { return reused }
        let output = try await base.encodeFeatures(mel)
        if let output { reuse.remember(output, for: mel) }
        return output
    }
}

/// The Notetaker's handle on the app's one WhisperKit engine.
///
/// Loading and model state are the engine's own, so a meeting started while
/// dictation is ready starts at once. Inference goes through the engine's
/// queue under `.meeting`, which keeps the meeting's recent language apart from
/// dictation's and keeps per-window timing out of the dictation log.
final class WhisperKitMeetingClient: TranscriptionService {
    let service: WhisperKitTranscriptionService

    init(service: WhisperKitTranscriptionService) {
        self.service = service
    }

    var identifier: String { service.identifier }
    var displayName: String { service.displayName }

    func supports(_ profile: LanguageProfile) -> Bool {
        service.supports(profile)
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        await service.modelState(for: profile)
    }

    func prepare(for profile: LanguageProfile) async throws {
        try await service.prepare(for: profile)
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        try await service.transcribe(utterance, profile: profile, caller: .meeting)
    }
}

/// Whose turn it is on a resource that runs one job at a time, in arrival
/// order. Pure bookkeeping: the owner stores whatever wakes a waiter and
/// resumes what `leave` hands back.
struct InferenceTurns<Waiter> {
    private(set) var isBusy = false
    private var waiting: [Waiter] = []

    var waitingCount: Int { waiting.count }

    /// Takes the turn if nobody holds it. False means the caller must `wait`.
    mutating func enter() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    mutating func wait(_ waiter: Waiter) {
        waiting.append(waiter)
    }

    /// Ends the current turn. The returned waiter now holds the turn and must
    /// be woken; nil means the resource is free.
    mutating func leave() -> Waiter? {
        guard !waiting.isEmpty else {
            isBusy = false
            return nil
        }
        return waiting.removeFirst()
    }
}
