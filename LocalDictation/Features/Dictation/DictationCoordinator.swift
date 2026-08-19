import Foundation

/// Orchestrates permission, hotkey, and capture services into the Phase 1 slice:
/// hotkey press -> capture -> bounded utterance -> diagnostics.
///
/// All orchestration state lives on the main actor. Every OS integration is
/// injected as a protocol so the coordinator can be tested with fakes and without
/// a microphone or a permission dialog.
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .launching
    @Published private(set) var diagnostics: CaptureDiagnostics = .empty
    @Published private(set) var registeredHotkey: HotkeyBinding?
    @Published var configuration: AudioCaptureConfiguration

    /// Raw transcript of the most recent utterance. Memory only, and released
    /// to the user solely through an explicit copy action.
    @Published private(set) var transcript: Transcript?
    /// The transcript after cleanup, risk marking, and the review decision.
    @Published private(set) var result: DictationResult?
    /// Set inside review when the user asks for the raw transcript back.
    /// Reset on every new utterance, so a recovery never leaks into the next one.
    @Published var prefersRawTranscript = false
    @Published private(set) var transcriptionModelState: TranscriptionModelState = .unavailable("No speech engine configured", needsUserAction: true)
    /// Selected language profile. Explicit, never inferred per utterance.
    @Published var languageProfile: LanguageProfile
    /// The user's vocabulary — the only state in the app that survives a launch.
    @Published private(set) var glossary: Glossary = .empty
    @Published private(set) var glossaryErrorDescription: String?
    /// Accessibility trust, which gates insertion and nothing else.
    @Published private(set) var accessibilityAuthorization: AccessibilityAuthorization = .notTrusted
    /// How the last finished result left the app, or `nil` when none has.
    @Published private(set) var lastInsertion: InsertionOutcome?
    /// Whether a result that needs no review goes straight into the target.
    ///
    /// On by default, because that is the phase's whole point: speak, release,
    /// and the words are in the document. Off is for users who want the
    /// keystroke to be theirs.
    @Published var insertsAutomatically = true

    let binding: HotkeyBinding

    private let permissionService: any MicrophonePermissionService
    private let hotkeyService: any HotkeyService
    private let captureService: any AudioCaptureService
    private let transcriptionService: (any TranscriptionService)?
    private let cleanupService: any CleanupService
    private let riskEngine: RiskEngine
    private let reviewPolicy: ReviewPolicy
    private let glossaryStore: (any GlossaryStore)?
    private let fragmentPlayer: (any AudioFragmentPlayer)?
    private let accessibilityService: (any AccessibilityPermissionService)?
    private let insertionService: (any TextInsertionService)?

    private var machine = RecordingStateMachine()
    private var pollTimer: Timer?
    private var captureIsRunning = false
    private var pendingEndReason: UtteranceEndReason?
    private let pollInterval: TimeInterval
    private var transcriptionTask: Task<Void, Never>?
    /// Incremented whenever a transcription is started or superseded. A result
    /// carrying a stale generation is dropped instead of being published.
    private var transcriptionGeneration = 0

    /// The captured samples, held only while something still needs them.
    ///
    /// Its lifetime is bounded by the review decision rather than by the end of
    /// the interaction: when the decision is "no review needed" this is cleared
    /// at that instant, before the user has done anything at all.
    private var retainedAudio: RetainedAudio?

    /// The application the current utterance was spoken into, captured when
    /// recording started rather than read when inserting.
    private var insertionTarget: InsertionTarget?
    private var insertionTask: Task<Void, Never>?
    /// Runs only while Accessibility trust is missing. See `startTrustPolling`.
    private var trustPollTimer: Timer?
    /// Incremented whenever an insertion is started or superseded, so an
    /// outcome belonging to a replaced utterance is dropped instead of shown.
    private var insertionGeneration = 0

    #if DEBUG
    /// Retained in memory only, for the explicit debug export action. Replaced on
    /// every new utterance and never written to disk automatically.
    private(set) var lastUtteranceSamples: [Float] = []
    #endif

    init(
        permissionService: any MicrophonePermissionService,
        hotkeyService: any HotkeyService,
        captureService: any AudioCaptureService,
        transcriptionService: (any TranscriptionService)? = nil,
        cleanupService: any CleanupService = ConservativeCleanupService(),
        riskEngine: RiskEngine = .standard(),
        reviewPolicy: ReviewPolicy = .default,
        glossaryStore: (any GlossaryStore)? = nil,
        fragmentPlayer: (any AudioFragmentPlayer)? = nil,
        accessibilityService: (any AccessibilityPermissionService)? = nil,
        insertionService: (any TextInsertionService)? = nil,
        configuration: AudioCaptureConfiguration = .default,
        binding: HotkeyBinding = .optionSpace,
        languageProfile: LanguageProfile = .default,
        pollInterval: TimeInterval = 0.1
    ) {
        self.permissionService = permissionService
        self.hotkeyService = hotkeyService
        self.captureService = captureService
        self.transcriptionService = transcriptionService
        self.cleanupService = cleanupService
        self.riskEngine = riskEngine
        self.reviewPolicy = reviewPolicy
        self.glossaryStore = glossaryStore
        self.fragmentPlayer = fragmentPlayer
        self.accessibilityService = accessibilityService
        self.insertionService = insertionService
        self.configuration = configuration
        self.binding = binding
        self.languageProfile = languageProfile
        self.pollInterval = pollInterval
    }

    var transcriptionEngineName: String? { transcriptionService?.displayName }
    var hasTranscriptionEngine: Bool { transcriptionService != nil }

    // MARK: - Lifecycle

    /// Reads the current authorization without prompting and registers the hotkey.
    func activate() {
        loadGlossary()
        apply(.authorizationResolved(permissionService.currentAuthorization))
        refreshAccessibilityAuthorization()
        registerHotkey()
        loadInstalledModel()
    }

    /// Loads weights that are already on disk, in the background, at launch.
    ///
    /// Never downloads. The 600 MB fetch stays bound to the explicit button,
    /// and this only covers the case that needs neither the network nor the
    /// user: reading installed weights into memory. That load costs seconds on
    /// a warm system, and paying it at launch is the difference between a user
    /// who waits and a user who never notices.
    private func loadInstalledModel() {
        guard let transcriptionService else { return }
        let profile = languageProfile
        Task { [weak self] in
            let state = await transcriptionService.modelState(for: profile)
            guard let self else { return }
            // Reading the state took a hop, and in that time the user may have
            // pressed the button themselves. This is a launch convenience, not
            // an authority on the state: whatever is already under way wins.
            guard !transcriptionModelState.isPreparing, !transcriptionModelState.isReady else { return }
            guard state.canPrepareUnattended else {
                transcriptionModelState = state
                return
            }
            await prepareTranscriptionModel()
        }
    }

    func deactivate() {
        stopPolling()
        stopTrustPolling()
        cancelInsertion()
        cancelTranscription()
        fragmentPlayer?.stop()
        releaseRetainedAudio()
        hotkeyService.unregister()
        registeredHotkey = nil
        if captureIsRunning {
            captureIsRunning = false
            let service = captureService
            Task { _ = await service.stop(reason: .interrupted) }
        }
    }

    /// Re-reads authorization, e.g. after the user returns from System Settings.
    func refreshAuthorization() {
        // Accessibility trust changes out of band and has no notification, so
        // it is re-read even while the app is busy: this costs one cheap call
        // and is how the app notices a grant at all.
        refreshAccessibilityAuthorization()
        guard !state.isBusy else { return }
        apply(.authorizationResolved(permissionService.currentAuthorization))
        if permissionService.currentAuthorization.allowsCapture, registeredHotkey == nil {
            registerHotkey()
        }
    }

    // MARK: - Permission

    var canRequestPermission: Bool { permissionService.currentAuthorization.isRequestable }

    func requestMicrophoneAccess() async {
        guard permissionService.currentAuthorization.isRequestable else {
            apply(.authorizationResolved(permissionService.currentAuthorization))
            return
        }

        apply(.permissionRequestStarted)
        let resolved = await permissionService.requestAccess()
        apply(.authorizationResolved(resolved))
        if resolved.allowsCapture, registeredHotkey == nil {
            registerHotkey()
        }
    }

    func openSystemSettings() {
        permissionService.openSystemSettings()
    }

    // MARK: - Failure recovery

    func recoverFromFailure() {
        guard case .failed = state else { return }
        apply(.recoveryRequested)
        if registeredHotkey == nil {
            registerHotkey()
        }
        apply(.authorizationResolved(permissionService.currentAuthorization))
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        do {
            try hotkeyService.register(binding) { [weak self] event in
                self?.receiveHotkeyEvent(event)
            }
            registeredHotkey = binding
        } catch let error as HotkeyRegistrationError {
            registeredHotkey = nil
            Log.hotkey.error("Hotkey registration failed: \(error.message, privacy: .public)")
            apply(.hotkeyRegistrationFailed(error.message))
        } catch {
            registeredHotkey = nil
            apply(.hotkeyRegistrationFailed("\(error)"))
        }
    }

    /// Hotkey callbacks arrive on the main thread from the Carbon event target.
    /// Staying synchronous there preserves press/release ordering.
    private nonisolated func receiveHotkeyEvent(_ event: HotkeyEvent) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.handle(event) }
        } else {
            Task { @MainActor in self.handle(event) }
        }
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed:
            beginCapture()
        case .released:
            endCapture(reason: .hotkeyRelease)
        }
    }

    // MARK: - Capture

    private func beginCapture() {
        guard apply(.hotkeyPressed) else { return }

        // A new utterance supersedes whatever is still being transcribed or
        // reviewed, and clears the previous result so the copy action is never
        // ambiguous about which utterance it belongs to. The retained audio of
        // the superseded utterance goes with it.
        cancelTranscription()
        cancelInsertion()
        fragmentPlayer?.stop()
        releaseRetainedAudio()
        transcript = nil
        result = nil
        prefersRawTranscript = false
        lastInsertion = nil
        pendingEndReason = nil

        // The target is captured here, at the start, and not read again when
        // the text is ready. By then the user may have moved on: transcription
        // takes seconds and a review takes as long as reading does.
        insertionTarget = insertionService?.captureTarget()
        let captureConfiguration = configuration
        let service = captureService
        let interruptionHandler: @Sendable (AudioCaptureError) -> Void = { [weak self] error in
            Task { @MainActor in self?.handleInterruption(error) }
        }

        Task { [weak self] in
            do {
                let format = try await service.start(configuration: captureConfiguration, onInterruption: interruptionHandler)
                self?.captureDidStart(format: format)
            } catch {
                self?.captureDidFail(error)
            }
        }
    }

    private func captureDidStart(format: CaptureFormatDescription) {
        captureIsRunning = true
        diagnostics.format = format
        diagnostics.lastErrorDescription = nil
        diagnostics.snapshot = CaptureSnapshot(
            capacityFrames: format.bufferCapacityFrames,
            sampleRate: format.outputSampleRate
        )
        apply(.captureStarted)

        switch machine.state {
        case .recording:
            startPolling()
        case .finishing:
            // The hotkey was released while the engine was still starting.
            finishCapture(reason: pendingEndReason ?? .hotkeyRelease)
        default:
            break
        }
    }

    private func captureDidFail(_ error: any Error) {
        captureIsRunning = false
        let message = (error as? AudioCaptureError)?.message ?? error.localizedDescription
        Log.audio.error("Capture start failed: \(message, privacy: .public)")
        diagnostics.lastErrorDescription = message
        apply(.captureFailed(.captureStart(message)))
    }

    private func endCapture(reason: UtteranceEndReason) {
        let event: RecordingEvent = reason == .maximumDuration ? .maximumDurationReached : .hotkeyReleased
        guard apply(event) else { return }

        pendingEndReason = reason
        guard captureIsRunning else {
            // Still starting; `captureDidStart` performs the stop.
            return
        }
        finishCapture(reason: reason)
    }

    private func finishCapture(reason: UtteranceEndReason) {
        stopPolling()
        let service = captureService
        Task { [weak self] in
            let utterance = await service.stop(reason: reason)
            self?.captureDidFinish(utterance)
        }
    }

    private func captureDidFinish(_ utterance: CapturedUtterance?) {
        captureIsRunning = false
        pendingEndReason = nil

        if let utterance {
            let summary = UtteranceSummary(utterance)
            diagnostics.lastUtterance = summary
            diagnostics.snapshot = CaptureSnapshot(
                frameCount: utterance.frameCount,
                capacityFrames: max(diagnostics.snapshot.capacityFrames, utterance.frameCount),
                peakLevel: utterance.peakLevel,
                droppedFrameCount: utterance.droppedFrameCount,
                voiceActivity: utterance.voiceActivity,
                sampleRate: utterance.sampleRate
            )
            // Held until the review decision, and no longer. Phase 3 gives the
            // recording a lifetime bounded by that decision rather than by the
            // end of the interaction.
            retainedAudio = RetainedAudio(samples: utterance.samples, sampleRate: utterance.sampleRate)
            #if DEBUG
            // Debug-only export buffer, compiled out of every shipping build.
            // It deliberately outlives the review decision so the last
            // utterance can still be exported by hand; the product path above
            // is the one bounded by the decision.
            lastUtteranceSamples = utterance.samples
            #endif
            Log.audio.info(
                "Utterance completed: \(String(format: "%.2f", summary.duration)) s at \(Int(summary.sampleRate)) Hz, dropped \(summary.droppedFrameCount), reason \(summary.endReason.rawValue, privacy: .public)"
            )
        }

        apply(.utteranceCompleted)

        // Nothing else in the app can reach the samples once transcription
        // declines to start, so they go immediately rather than waiting for the
        // next utterance to clear them.
        if let utterance, startTranscription(for: utterance) {
            return
        }
        releaseRetainedAudio()
    }

    // MARK: - Transcription

    /// Explicit user action: load or download the engine's model.
    ///
    /// Safe to call more than once: the engine coalesces concurrent calls into
    /// one load, so a second press joins the first rather than starting a
    /// competing download.
    func prepareTranscriptionModel() async {
        guard let transcriptionService else { return }
        let profile = languageProfile
        transcriptionModelState = .preparing(ModelPreparation(phase: .loading))
        // Logged on both ends. Preparing a cold model runs for minutes, and
        // without a start and a finish there is no way to tell a slow load from
        // a stuck one.
        Log.transcription.info("Preparing speech model for \(profile.displayName, privacy: .public)")
        let started = Date()
        // The engine knows which phase it is in and how far a download has got,
        // but `prepare` only returns at the end. Polling is what turns a silent
        // multi-minute wait into a label that changes.
        let phasePolling = pollPreparationPhase(of: transcriptionService, for: profile)
        defer { phasePolling.cancel() }
        do {
            try await transcriptionService.prepare(for: profile)
            phasePolling.cancel()
            transcriptionModelState = await transcriptionService.modelState(for: profile)
            // Explicitly public: string interpolations are redacted by default,
            // and a timing with no content in it is exactly what this log is
            // for. Without the annotation it arrives as "<private> s".
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            Log.transcription.info("Speech model ready after \(elapsed, privacy: .public) s")
        } catch {
            let message = (error as? TranscriptionError)?.message ?? error.localizedDescription
            Log.transcription.error("Model preparation failed: \(message, privacy: .public)")
            transcriptionModelState = .failed(message)
        }
    }

    /// Mirrors the engine's preparation phase into the published state until
    /// the load ends. Only overwrites a `preparing` state, so it can never
    /// stomp on the final `ready` or `failed`.
    private func pollPreparationPhase(
        of service: any TranscriptionService,
        for profile: LanguageProfile
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let state = await service.modelState(for: profile)
                guard let self, state.isPreparing, self.transcriptionModelState.isPreparing else { return }
                self.transcriptionModelState = state
            }
        }
    }

    func refreshTranscriptionModelState() async {
        guard let transcriptionService else { return }
        transcriptionModelState = await transcriptionService.modelState(for: languageProfile)
    }

    func clearTranscript() {
        transcript = nil
        result = nil
        prefersRawTranscript = false
        releaseRetainedAudio()
    }

    // MARK: - Insertion

    /// Whether the app is able to put text into another application at all.
    var canInsert: Bool { insertionService != nil }
    var needsAccessibilityTrust: Bool {
        insertionService != nil && accessibilityAuthorization != .trusted
    }
    /// What the user is told the text will go into. `nil` when there is
    /// nothing to insert into, which is a normal state rather than an error.
    var insertionTargetName: String? { insertionTarget?.displayName }

    /// A finished result the user can still act on from the menu.
    var hasInsertableResult: Bool {
        guard let result, !result.isEmpty else { return false }
        return state == .ready
    }

    func refreshAccessibilityAuthorization() {
        guard let accessibilityService else { return }
        let resolved = accessibilityService.currentAuthorization
        if resolved.allowsInsertion {
            stopTrustPolling()
        } else {
            startTrustPolling()
        }
        guard resolved != accessibilityAuthorization else { return }
        accessibilityAuthorization = resolved
        Log.permissions.info("Accessibility authorization now \(resolved.rawValue, privacy: .public)")
    }

    /// Watches for the grant while it is missing.
    ///
    /// macOS sends no notification when Accessibility trust changes, so the app
    /// has to look. The obvious moment — "when the user comes back to the app"
    /// — turned out not to exist for this app: it has no Dock icon, and opening
    /// a menu bar panel does not reliably activate it or re-run a view's
    /// `onAppear`. Someone could therefore grant access in System Settings and
    /// find the app still claiming it had none, which is indistinguishable from
    /// the grant not working.
    ///
    /// So while trust is missing, and only then, the app asks every two
    /// seconds. The call is cheap, the timer stops the moment the answer
    /// changes, and the grant simply appears without anyone pressing anything.
    private func startTrustPolling() {
        guard accessibilityService != nil, trustPollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAccessibilityAuthorization()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func stopTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
    }

    /// Read by the test that asserts the watch ends when the answer arrives.
    var isWatchingForAccessibilityTrust: Bool { trustPollTimer != nil }

    /// Shows the system prompt. Trust is granted out of band, so the answer
    /// arrives through `refreshAuthorization()` when the user comes back.
    func requestAccessibilityTrust() {
        guard let accessibilityService else { return }
        accessibilityAuthorization = accessibilityService.requestTrust()
    }

    func openAccessibilitySettings() {
        accessibilityService?.openSystemSettings()
    }

    /// Sends the current result to the target application.
    ///
    /// The text is whichever of the two the user is looking at, so a raw
    /// transcript they recovered is the one that lands — the same rule the copy
    /// action already follows.
    func insertCurrentResult() {
        guard let result, !result.isEmpty else { return }
        performInsertion(of: result.text(preferringRaw: prefersRawTranscript))
    }

    /// Returns whether the insertion actually started, so the caller can
    /// finish the utterance its own way when it did not. Without an insertion
    /// service the app is in the Phase 3 world: the result stays here and the
    /// copy button is the way out.
    @discardableResult
    private func performInsertion(of text: String) -> Bool {
        guard let insertionService, !text.isEmpty else { return false }
        guard apply(.insertionStarted) else { return false }

        insertionGeneration += 1
        let generation = insertionGeneration
        let target = insertionTarget
        insertionTask = Task { [weak self] in
            let outcome = await insertionService.insert(text, into: target)
            guard let self, !Task.isCancelled else { return }
            self.insertionDidFinish(outcome, generation: generation)
        }
        return true
    }

    private func insertionDidFinish(_ outcome: InsertionOutcome, generation: Int) {
        // A superseding recording moved the app on. Reporting where the text of
        // a replaced utterance went would describe something the user has
        // already abandoned.
        guard generation == insertionGeneration else { return }
        insertionTask = nil
        lastInsertion = outcome
        diagnostics.lastInsertion = InsertionDiagnostics(outcome: outcome, target: insertionTarget)
        insertionTarget = nil
        // A clipboard fallback for want of trust is the moment the ask makes
        // sense, so the displayed state is re-read before the menu shows it.
        refreshAccessibilityAuthorization()
        Log.insertion.info("Insertion outcome \(outcome.logLabel, privacy: .public)")
        apply(.insertionFinished)
    }

    private func cancelInsertion() {
        insertionGeneration += 1
        insertionTask?.cancel()
        insertionTask = nil
        insertionTarget = nil
    }

    // MARK: - Review

    /// Whether the app is still holding the recording. Read by the tests that
    /// assert the recording's lifetime is bounded by the review decision.
    var hasRetainedAudio: Bool { retainedAudio != nil }
    var retainedAudioFrameCount: Int { retainedAudio?.frameCount ?? 0 }

    var canReplayFragments: Bool { fragmentPlayer != nil && retainedAudio != nil }

    /// Ends a shown review. Both outcomes release the audio; they differ in
    /// what happens to the text.
    ///
    /// Accepting is what authorizes the insertion — review always completes
    /// before anything leaves the app, and a dismissal inserts nothing at all,
    /// because dismissing is the user saying no.
    func completeReview(_ outcome: ReviewOutcome) {
        guard state.isReviewing else { return }
        fragmentPlayer?.stop()
        releaseRetainedAudio()
        Log.application.info("Review \(outcome.rawValue, privacy: .public)")

        switch outcome {
        case .accepted:
            let text = result?.text(preferringRaw: prefersRawTranscript) ?? ""
            if performInsertion(of: text) { return }
        case .dismissed:
            insertionTarget = nil
        }
        apply(.reviewCompleted)
    }

    func acceptReview() { completeReview(.accepted) }
    func dismissReview() { completeReview(.dismissed) }

    /// Replays one flagged fragment from memory.
    ///
    /// Only a flagged span may be replayed, per `docs/PHASE_3.md`: replay is an
    /// affordance of the review step, not a general way to listen back to a
    /// recording the app is otherwise finished with.
    func replay(_ span: RiskSpan) {
        guard let fragmentPlayer, let audio = retainedAudio else { return }
        guard let result, result.flaggedSpans.contains(span) else { return }
        guard let start = span.start, let end = span.end else { return }

        // A word clipped exactly at its token boundary is hard to recognize, so
        // the window is padded slightly on both sides.
        let padding = 0.15
        let samples = audio.slice(from: max(start - padding, 0), to: min(end + padding, audio.duration))
        do {
            try fragmentPlayer.play(samples: samples, sampleRate: audio.sampleRate)
        } catch {
            let message = (error as? AudioPlaybackError)?.message ?? error.localizedDescription
            diagnostics.lastErrorDescription = message
            Log.audio.error("Fragment replay failed: \(message, privacy: .public)")
        }
    }

    func stopReplay() {
        fragmentPlayer?.stop()
    }

    private func releaseRetainedAudio() {
        guard retainedAudio != nil else { return }
        retainedAudio = nil
        Log.audio.debug("Retained utterance audio released")
    }

    // MARK: - Glossary

    private func loadGlossary() {
        guard let glossaryStore else { return }
        do {
            glossary = try glossaryStore.load()
            glossaryErrorDescription = nil
        } catch {
            glossary = .empty
            glossaryErrorDescription = (error as? GlossaryStoreError)?.message ?? error.localizedDescription
            Log.application.error("Glossary load failed: \(self.glossaryErrorDescription ?? "", privacy: .public)")
        }
    }

    @discardableResult
    func addGlossaryTerm(_ term: String, language: SpeechLanguage) -> Bool {
        var updated = glossary
        guard updated.add(term, language: language) else { return false }
        glossary = updated
        persistGlossary()
        return true
    }

    func removeGlossaryTerm(id: UUID) {
        var updated = glossary
        guard updated.remove(id: id) else { return }
        glossary = updated
        persistGlossary()
    }

    private func persistGlossary() {
        guard let glossaryStore else { return }
        do {
            try glossaryStore.save(glossary)
            glossaryErrorDescription = nil
        } catch {
            glossaryErrorDescription = (error as? GlossaryStoreError)?.message ?? error.localizedDescription
            Log.application.error("Glossary save failed: \(self.glossaryErrorDescription ?? "", privacy: .public)")
        }
    }

    var glossaryLocationDescription: String? { glossaryStore?.locationDescription }

    /// Returns whether a request was actually started, so the caller knows
    /// whether anything still needs the retained audio.
    @discardableResult
    private func startTranscription(for utterance: CapturedUtterance) -> Bool {
        guard let transcriptionService else { return false }
        guard !utterance.samples.isEmpty else { return false }

        let profile = languageProfile
        guard transcriptionService.supports(profile) else {
            guard apply(.transcriptionStarted) else { return false }
            apply(.transcriptionFailed(TranscriptionError.unsupportedProfile(profile).message))
            return false
        }
        guard apply(.transcriptionStarted) else { return false }

        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        transcriptionTask = Task { [weak self] in
            do {
                let result = try await transcriptionService.transcribe(utterance, profile: profile)
                try Task.checkCancellation()
                self?.transcriptionDidFinish(result, generation: generation)
            } catch is CancellationError {
                return
            } catch TranscriptionError.cancelled {
                return
            } catch {
                let message = (error as? TranscriptionError)?.message ?? error.localizedDescription
                self?.transcriptionDidFail(message, generation: generation)
            }
        }
        return true
    }

    /// Drops the in-flight request and invalidates its generation, so a result
    /// already in flight cannot land after the caller moved on.
    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionGeneration += 1
    }

    private func transcriptionDidFinish(_ transcript: Transcript, generation: Int) {
        guard generation == transcriptionGeneration else { return }
        transcriptionTask = nil
        self.transcript = transcript
        diagnostics.lastTranscript = TranscriptDiagnostics(transcript)
        Log.transcription.info(
            """
            Transcript ready: engine \(transcript.engineIdentifier, privacy: .public),             profile \(transcript.profile.shortLabel, privacy: .public),             \(transcript.tokens.count) tokens, \(String(format: "%.2f", transcript.processingDuration)) s inference
            """
        )

        let result = analyze(transcript)
        self.result = result
        prefersRawTranscript = false
        diagnostics.lastRisk = RiskDiagnostics(result)
        Log.application.info(
            """
            Result ready: \(result.cleanup.edits.count) edits, \(result.spans.count) spans, \(result.flaggedSpans.count) flagged, review \(result.requiresReview ? "required" : "not needed", privacy: .public)
            """
        )

        if result.requiresReview {
            guard apply(.reviewRequired) else { return }
        } else {
            // The decision is "nothing worth saying", so the recording's job is
            // over. Releasing here rather than at the end of the interaction is
            // the whole point of deciding early.
            releaseRetainedAudio()
            // And this is the phase's whole point: nothing worth saying means
            // nothing is said. No window, no click — the words appear where the
            // user was already typing.
            if insertsAutomatically, performInsertion(of: result.cleanedText) { return }
            apply(.transcriptionFinished)
        }
    }

    /// Cleanup, risk marking, and the review decision for one transcript.
    ///
    /// Pure with respect to the coordinator's state: it reads the injected
    /// services and the current glossary and returns a value. That is what lets
    /// the same three stages run inside the measurement harness with no app.
    private func analyze(_ transcript: Transcript) -> DictationResult {
        let language = Self.cleanupLanguage(for: transcript)
        let cleanup = cleanupService.clean(transcript.text, language: language)
        let spans = riskEngine.analyze(
            cleanup: cleanup,
            tokens: transcript.tokens,
            profile: transcript.profile,
            glossary: glossary.entries(for: transcript.profile)
        )
        let decision = ReviewCoordinator.decide(
            spans: spans,
            policy: reviewPolicy,
            isEmptyResult: cleanup.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        return DictationResult(transcript: transcript, cleanup: cleanup, spans: spans, decision: decision)
    }

    /// Cleanup rules are language-keyed, so the rules that run must match the
    /// language actually spoken — the engine's own detection when it reports
    /// one inside the selected profile, and the profile's primary otherwise.
    static func cleanupLanguage(for transcript: Transcript) -> SpeechLanguage {
        if let detected = transcript.detectedLanguage, transcript.profile.contains(detected) {
            return detected
        }
        return transcript.profile.primary
    }

    private func transcriptionDidFail(_ message: String, generation: Int) {
        guard generation == transcriptionGeneration else { return }
        transcriptionTask = nil
        diagnostics.lastErrorDescription = message
        // A failed transcription produces no review, so nothing in the app can
        // still use the recording. It goes now rather than lingering until the
        // next utterance.
        releaseRetainedAudio()
        Log.transcription.error("Transcription failed: \(message, privacy: .public)")
        apply(.transcriptionFailed(message))
    }

    private func handleInterruption(_ error: AudioCaptureError) {
        guard state.isCapturing else { return }
        diagnostics.lastErrorDescription = error.message
        Log.audio.error("Capture interrupted: \(error.message, privacy: .public)")
        guard apply(.captureInterrupted(.captureInterrupted(error.message))) else { return }
        stopPolling()

        let wasRunning = captureIsRunning
        captureIsRunning = false

        if wasRunning {
            let service = captureService
            Task { _ = await service.stop(reason: .interrupted) }
        }
    }

    // MARK: - Diagnostics polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollDiagnostics()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Reads live counters at UI cadence. Polling keeps the audio thread free of
    /// any main-actor hop or allocation.
    func pollDiagnostics() {
        guard machine.state == .recording else { return }
        let snapshot = captureService.snapshot()
        diagnostics.snapshot = snapshot

        if snapshot.reachedCapacity || snapshot.voiceActivity.state == .endedByMaximumDuration {
            Log.audio.notice("Maximum utterance duration reached; finishing capture")
            endCapture(reason: .maximumDuration)
        }
    }

    // MARK: - State plumbing

    @discardableResult
    private func apply(_ event: RecordingEvent) -> Bool {
        let outcome = machine.apply(event)
        switch outcome {
        case let .transitioned(from, to):
            // Re-reading authorization re-applies the same state; that is not a
            // transition and should not appear in the diagnostics trail.
            if from != to {
                Log.application.debug("State \(String(describing: from), privacy: .public) -> \(String(describing: to), privacy: .public)")
            }
            state = to
            if case let .failed(failure) = to {
                diagnostics.lastErrorDescription = failure.message
            }
            return true
        case .rejected:
            return false
        }
    }

    #if DEBUG
    /// Encodes the last utterance for the explicit debug export action.
    /// Returns `nil` when nothing has been captured in this session.
    func makeDebugWAVData() -> Data? {
        guard !lastUtteranceSamples.isEmpty else { return nil }
        return WAVEncoder.encode(samples: lastUtteranceSamples, sampleRate: AudioTargetFormat.sampleRate)
    }
    #endif
}

extension DictationCoordinator {
    /// Live composition root.
    static func makeLive() -> DictationCoordinator {
        // One trust reader, shared: the coordinator shows the state and the
        // insertion service gates on it, and two readers could disagree.
        let accessibility = AXAccessibilityPermissionService()
        return DictationCoordinator(
            permissionService: AVCaptureMicrophonePermissionService(),
            hotkeyService: CarbonHotkeyService(),
            captureService: AVAudioEngineCaptureService(),
            // Development default rather than a final decision: WhisperKit is
            // the only admitted candidate that returns per-token confidence,
            // which Phase 3 requires. `AppleSpeechTranscriptionService` stays in
            // the codebase as the comparison the benchmark scores it against.
            transcriptionService: WhisperKitTranscriptionService(),
            cleanupService: ConservativeCleanupService(),
            riskEngine: .standard(),
            reviewPolicy: .default,
            glossaryStore: FileGlossaryStore(),
            fragmentPlayer: AVAudioEngineFragmentPlayer(),
            accessibilityService: accessibility,
            insertionService: AXTextInsertionService(permissionService: accessibility)
        )
    }
}
