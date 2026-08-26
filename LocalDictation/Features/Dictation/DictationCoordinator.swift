import Combine
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
    /// Whether the last result is worth pointing at and the user has not looked
    /// yet. This is the whole of the indicator's state: it lights the menu bar
    /// triangle and the fading chip, and nothing about it blocks anything.
    ///
    /// It clears three ways — the user opens the review, the user dismisses the
    /// chip, or the next dictation starts. A pending mark never survives into
    /// the utterance after it, because a triangle that might be about the last
    /// sentence or the one before it says nothing at all.
    @Published private(set) var attentionIsPending = false
    /// Whether the review panel is on screen. Presentation, not lifecycle: the
    /// text is already in the user's document by the time this can be true.
    @Published private(set) var isShowingReview = false
    /// Why the last press produced no text, when it produced none.
    ///
    /// The counterpart of `attentionIsPending` for the opposite outcome. A
    /// result with nothing in it inserts nothing, needs no review, and used to
    /// leave the app saying nothing at all — which is indistinguishable from
    /// the hotkey not working. It clears the same way the indicator does: the
    /// user dismisses it, or the next dictation starts.
    @Published private(set) var silentResult: SilentResult?
    /// Why a recording ended before the user finished it, when one did.
    ///
    /// A recording is not the interruption's to throw away. An input device
    /// changing mid-sentence — AirPods connecting, a dock being plugged in,
    /// a headset going to sleep — used to end the utterance in `.failed`
    /// with the captured audio discarded, which is the app taking back words
    /// the user had already said. `docs/PHASE_6.md` states the rule for a
    /// trial running out mid-utterance, and it is the same rule.
    @Published private(set) var captureInterruption: AudioCaptureError?
    @Published private(set) var transcriptionModelState: TranscriptionModelState = .unavailable("No speech engine configured", needsUserAction: true)
    /// Selected language profile. Explicit, never inferred per utterance,
    /// and remembered: a four-language product that forgets which two you
    /// speak is a product that asks the same question every morning.
    @Published var languageProfile: LanguageProfile { didSet { persistPreferences() } }
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
    @Published var insertsAutomatically = true { didSet { persistPreferences() } }
    /// Whether this Mac may dictate, and what it should be told if not.
    ///
    /// Republished from `EntitlementService` rather than owned here, so the
    /// views observe one object and the licensing rules stay in a type that can
    /// be tested with a clock.
    @Published private(set) var entitlement: EntitlementState = .ungated(.untouched)

    /// The key combination that records, and how it behaves.
    ///
    /// Published rather than constant from here on: ⌥Space is a default, not
    /// a law, and on a Mac where something else already owns it the app was
    /// previously unusable with no way out from inside it.
    @Published private(set) var binding: HotkeyBinding
    /// Hold to talk, or press twice. `docs/PRODUCT_SCOPE.md` has listed both
    /// since the first draft.
    @Published private(set) var activation: RecordingActivation
    /// Set when settings could not be read or written. Never fatal: the app
    /// dictates perfectly well with defaults it could not save.
    @Published private(set) var preferencesErrorDescription: String?
    /// Whether the app is waiting for the user to press the combination they
    /// want. The current shortcut is unregistered for the duration, so what
    /// they press reaches the settings window instead of opening a
    /// microphone.
    @Published private(set) var isCapturingHotkey = false

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
    private let entitlementService: EntitlementService?
    private let preferencesStore: (any PreferencesStore)?

    private var machine = RecordingStateMachine()
    private var pollTimer: Timer?
    private var captureIsRunning = false
    private var pendingEndReason: UtteranceEndReason?
    private let pollInterval: TimeInterval
    private var transcriptionTask: Task<Void, Never>?
    /// Incremented whenever a transcription is started or superseded. A result
    /// carrying a stale generation is dropped instead of being published.
    private var transcriptionGeneration = 0
    /// Set while settings are being applied from the store, so the property
    /// observers that persist them do not write the file back as it is read.
    private var isApplyingPreferences = false

    /// The captured samples, held only while something still needs them.
    ///
    /// A result the policy prices as quiet clears this the instant it is
    /// analyzed, before the user has done anything at all. A result worth
    /// pointing at keeps it, because fragment replay is the review's whole
    /// reason for existing and the review now happens later, if at all — so the
    /// samples live until the user closes the review or starts the next
    /// utterance, whichever comes first. That is longer than Phase 3 held them
    /// and it is the price of not interrupting; `docs/PHASE_5.md` records it.
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
        entitlementService: EntitlementService? = nil,
        preferencesStore: (any PreferencesStore)? = nil,
        configuration: AudioCaptureConfiguration = .default,
        binding: HotkeyBinding = .optionSpace,
        activation: RecordingActivation = .pushToTalk,
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
        self.entitlementService = entitlementService
        self.preferencesStore = preferencesStore
        self.configuration = configuration
        self.binding = binding
        self.activation = activation
        self.languageProfile = languageProfile
        self.pollInterval = pollInterval
    }

    var transcriptionEngineName: String? { transcriptionService?.displayName }
    var hasTranscriptionEngine: Bool { transcriptionService != nil }

    // MARK: - Lifecycle

    /// Reads the current authorization without prompting and registers the hotkey.
    func activate() {
        loadPreferences()
        loadGlossary()
        startObservingEntitlement()
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
        // A trial can run out while the app sits in the menu bar, so the answer
        // is re-read here too rather than only at launch. It is a comparison of
        // dates, and it costs nothing.
        entitlementService?.refresh()
        guard !state.isBusy else { return }
        apply(.authorizationResolved(permissionService.currentAuthorization))
        if permissionService.currentAuthorization.allowsCapture, registeredHotkey == nil, !isCapturingHotkey {
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
        if resolved.allowsCapture, registeredHotkey == nil, !isCapturingHotkey {
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
        if registeredHotkey == nil, !isCapturingHotkey {
            registerHotkey()
        }
        apply(.authorizationResolved(permissionService.currentAuthorization))
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        if let error = tryRegister(binding) {
            registeredHotkey = nil
            Log.hotkey.error("Hotkey registration failed: \(error.message, privacy: .public)")
            apply(.hotkeyRegistrationFailed(error.message))
        }
    }

    /// Registers a binding and reports what went wrong, without touching any
    /// state beyond `registeredHotkey`.
    ///
    /// Separated from `registerHotkey` so a *new* binding can be tried while
    /// the old one is still known. Carbon has no way to ask whether a
    /// combination is free — the only way to find out is to register it — so
    /// the app has to be able to fail and put the working shortcut back.
    private func tryRegister(_ candidate: HotkeyBinding) -> HotkeyRegistrationError? {
        do {
            try hotkeyService.register(candidate) { [weak self] event in
                self?.receiveHotkeyEvent(event)
            }
            registeredHotkey = candidate
            return nil
        } catch let error as HotkeyRegistrationError {
            registeredHotkey = nil
            return error
        } catch {
            registeredHotkey = nil
            return .registrationFailed(status: 0)
        }
    }

    /// Changes the shortcut, or explains why it could not be changed.
    ///
    /// The old binding goes back the instant the new one is refused, and the
    /// user is left with a working app and a sentence — not with a shortcut
    /// that silently stopped existing because they picked one macOS had
    /// already taken.
    @discardableResult
    func changeHotkey(to candidate: HotkeyBinding) -> HotkeyRegistrationError? {
        guard candidate != binding else { return nil }
        // A shortcut with no modifier is registered system-wide against a
        // bare key, which takes that key away from every application on the
        // Mac including this one's own text fields.
        guard !candidate.modifiers.isEmpty else { return .noModifier }

        let previous = binding
        if let error = tryRegister(candidate) {
            Log.hotkey.error("Hotkey change refused: \(error.message, privacy: .public)")
            // Put the working one back. `tryRegister` unregisters before it
            // registers, so at this point nothing is listening at all.
            if let restoreError = tryRegister(previous) {
                apply(.hotkeyRegistrationFailed(restoreError.message))
            }
            return error
        }

        binding = candidate
        persistPreferences()
        Log.hotkey.info("Hotkey changed to \(candidate.displayString, privacy: .public)")
        // Registration failure is a state, so a successful change has to
        // clear it or the app stays broken-looking after it is fixed.
        if case .failed(.hotkeyRegistration) = state { recoverFromFailure() }
        return nil
    }

    func resetHotkey() {
        isCapturingHotkey = false
        if binding == .optionSpace {
            if registeredHotkey == nil { registerHotkey() }
            return
        }
        changeHotkey(to: .optionSpace)
    }

    /// Starts listening for the combination the user wants.
    ///
    /// The current shortcut is unregistered first, and that is the whole
    /// point: a registered Carbon hotkey consumes its combination before any
    /// window sees it, so leaving it in place would mean the one shortcut
    /// the user cannot press while choosing is the one they already have —
    /// and pressing it would start recording into the settings window.
    func beginHotkeyCapture() {
        guard !isCapturingHotkey else { return }
        isCapturingHotkey = true
        hotkeyService.unregister()
        registeredHotkey = nil
    }

    /// Stops listening and puts the existing shortcut back.
    ///
    /// Called for the escape key, for the cancel button, and when the
    /// settings window goes away — the last of those matters most, because a
    /// window closed mid-capture would otherwise leave the app with no
    /// shortcut at all and no sign of why.
    func cancelHotkeyCapture() {
        guard isCapturingHotkey else { return }
        isCapturingHotkey = false
        registerHotkey()
    }

    /// Takes the combination the user pressed.
    @discardableResult
    func finishHotkeyCapture(with candidate: HotkeyBinding) -> HotkeyRegistrationError? {
        guard isCapturingHotkey else { return changeHotkey(to: candidate) }
        isCapturingHotkey = false

        guard !candidate.modifiers.isEmpty else {
            // Nothing was registered while capturing, so the old shortcut
            // has to go back before the refusal is reported.
            registerHotkey()
            return .noModifier
        }
        guard candidate != binding else {
            registerHotkey()
            return nil
        }
        return changeHotkey(to: candidate)
    }

    /// Switches between holding the key and pressing it twice.
    func setActivation(_ activation: RecordingActivation) {
        guard activation != self.activation else { return }
        self.activation = activation
        persistPreferences()
        Log.hotkey.info("Recording activation is now \(activation.rawValue, privacy: .public)")
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
        switch activation {
        case .pushToTalk:
            switch event {
            case .pressed:
                beginCapture()
            case .released:
                endCapture(reason: .hotkeyRelease)
            }

        case .toggle:
            // Only the press carries meaning. Letting go of the key that
            // started the recording must not end it, which is the whole
            // difference between the two modes.
            guard event == .pressed else { return }
            if state.isCapturing {
                endCapture(reason: .hotkeyRelease)
            } else {
                beginCapture()
            }
        }
    }

    // MARK: - Capture

    private func beginCapture() {
        guard apply(.hotkeyPressed) else { return }

        // A new utterance supersedes whatever is still being transcribed or
        // reviewed, and clears the previous result so the copy action is never
        // ambiguous about which utterance it belongs to. The retained audio of
        // the superseded utterance goes with it, and so does any indicator
        // still lit for it.
        cancelTranscription()
        cancelInsertion()
        fragmentPlayer?.stop()
        releaseRetainedAudio()
        transcript = nil
        result = nil
        prefersRawTranscript = false
        lastInsertion = nil
        attentionIsPending = false
        silentResult = nil
        captureInterruption = nil
        isShowingReview = false
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
            // Held until the policy has priced the result. A quiet one releases
            // these immediately; one worth pointing at keeps them for replay.
            retainedAudio = RetainedAudio(samples: utterance.samples, sampleRate: utterance.sampleRate)
            #if DEBUG
            // Debug-only export buffer, compiled out of every shipping build.
            // It deliberately outlives the risk decision so the last
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
        noteCaptureProducedNothing(utterance)
        releaseRetainedAudio()
    }

    // MARK: - Silence

    /// Says so when a press ends with nothing to transcribe.
    ///
    /// Only where there is an engine: without one the app never offered
    /// recognition, and a notice about it would describe a feature that is not
    /// there. Never on top of a failure either — that already has its own
    /// sentence, and two explanations for one press is one more than the user
    /// can act on.
    private func noteCaptureProducedNothing(_ utterance: CapturedUtterance?) {
        guard transcriptionService != nil else { return }
        if case .failed = state { return }
        guard utterance?.samples.isEmpty ?? true else { return }
        noteSilence(
            .nothingHeard(
                duration: utterance?.duration ?? 0,
                peakLevel: utterance?.peakLevel ?? 0,
                inputDeviceName: diagnostics.format?.inputDeviceName
            )
        )
    }

    /// Prices an empty result: a microphone that heard nothing, or an engine
    /// that recognized nothing in what it did hear.
    ///
    /// The detector's own answer decides. `speechStart` is set the moment
    /// consecutive windows clear the speech threshold, so its absence is this
    /// Mac saying it never heard speech at all — a different problem from an
    /// engine returning no words, and one with a different fix.
    private func silence(for transcript: Transcript) -> SilentResult {
        let summary = diagnostics.lastUtterance
        let duration = summary?.duration ?? transcript.audioDuration
        guard summary?.speechStart != nil else {
            return .nothingHeard(
                duration: duration,
                peakLevel: summary?.peakLevel ?? 0,
                inputDeviceName: diagnostics.format?.inputDeviceName
            )
        }
        return .nothingRecognized(duration: duration, profileLabel: transcript.profile.displayName)
    }

    private func noteSilence(_ silence: SilentResult) {
        // A recording the system ended already has its sentence, and it is
        // the more useful one: "the input device changed" explains an empty
        // result, where "nothing was heard" sends the user to look at a
        // microphone that was working until it was unplugged.
        guard captureInterruption == nil else { return }
        silentResult = silence
        Log.application.info("Dictation produced nothing: \(silence.logLabel, privacy: .public)")
    }

    /// The sentence for a recording the system ended, when one was.
    var captureInterruptionMessage: String? { captureInterruption?.interruptionMessage }

    /// Puts the interruption notice out. Cleared by the next dictation anyway;
    /// this is for the user who has read it and wants their menu bar back.
    func dismissCaptureInterruption() {
        guard captureInterruption != nil else { return }
        captureInterruption = nil
    }

    /// Puts the notice out without waiting for the next dictation — the
    /// counterpart of `dismissAttention` for the press that produced nothing.
    func dismissSilentResult() {
        guard silentResult != nil else { return }
        silentResult = nil
        Log.application.info("Silent-result notice dismissed")
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
        attentionIsPending = false
        silentResult = nil
        isShowingReview = false
        fragmentPlayer?.stop()
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

    /// Whether there is a review to open at all.
    var canOpenReview: Bool { result?.hasAnythingToReview ?? false }

    /// Opens the review, and puts the indicator out.
    ///
    /// The indicator's only job was to get the user here. Once they have
    /// arrived it has nothing left to say, so it clears on opening rather than
    /// on closing — a triangle still lit behind an open review is telling the
    /// user about the thing they are looking at.
    func openReview() {
        guard canOpenReview else { return }
        attentionIsPending = false
        guard !isShowingReview else { return }
        isShowingReview = true
        Log.application.info("Review opened")
    }

    /// Closes the review and releases the recording it was holding.
    ///
    /// This is the last thing that can need the samples, so they go here. The
    /// user is not asked to confirm anything: the text has been in their
    /// document since the moment it was recognized.
    func closeReview() {
        guard isShowingReview else { return }
        isShowingReview = false
        fragmentPlayer?.stop()
        releaseRetainedAudio()
        prefersRawTranscript = false
        Log.application.info("Review closed")
    }

    /// Puts the indicator out without opening anything — the user glanced at
    /// the chip and decided the text was fine. The samples go with it, because
    /// the only thing that would have used them is the review they declined.
    func dismissAttention() {
        guard attentionIsPending, !isShowingReview else { return }
        attentionIsPending = false
        fragmentPlayer?.stop()
        releaseRetainedAudio()
        Log.application.info("Attention dismissed unopened")
    }

    /// Replays one flagged fragment from memory.
    ///
    /// Only a span the review actually shows may be replayed, per
    /// `docs/PHASE_3.md`: replay is an affordance of the review step, not a
    /// general way to listen back to a recording the app is otherwise finished
    /// with. Phase 5 widens that set from the flagged spans to the highlighted
    /// ones, because those are now what the open review puts in front of the
    /// user — and a mark with a dead play button beside it is worse than a mark
    /// with none.
    func replay(_ span: RiskSpan) {
        guard let fragmentPlayer, let audio = retainedAudio else { return }
        guard let result, result.highlightedSpans.contains(span) else { return }
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

    // MARK: - Licensing

    /// Whether the app has a licensing service at all. Without one — the Phase
    /// 5 world, and every test that does not care — nothing is gated.
    var hasEntitlementService: Bool { entitlementService != nil }
    var canRequestActivation: Bool { entitlementService?.canRequestActivation ?? false }
    var licenseAuthorityIsConfigured: Bool { entitlementService?.authorityIsConfigured ?? false }
    /// Shown so a user can quote it when a key has to be reissued for this Mac.
    var deviceIdentifier: String? { entitlementService?.deviceID }
    var licenseRecordLocation: String? { entitlementService?.recordLocationDescription }
    var licenseStoreErrorDescription: String? { entitlementService?.storeErrorDescription }

    private func startObservingEntitlement() {
        guard let entitlementService else { return }
        entitlementService.onChange = { [weak self] state in
            self?.applyEntitlement(state)
        }
        applyEntitlement(entitlementService.state)
    }

    /// The single point where a licensing verdict reaches the dictation
    /// machine.
    ///
    /// The microphone authorization travels with it because unlocking has to
    /// land on the state the Mac is actually in — a user who activated while
    /// microphone access was denied is not suddenly ready.
    private func applyEntitlement(_ state: EntitlementState) {
        entitlement = state
        apply(.entitlementResolved(state.lock, permissionService.currentAuthorization))
    }

    /// Accepts a pasted key. Returns the failure so the view can print the one
    /// sentence that says what to do about it.
    @discardableResult
    func enterLicenseKey(_ token: String) -> LicenseKeyError? {
        guard let entitlementService else { return .noAuthority }
        switch entitlementService.enter(key: token) {
        case .success:
            // Entering a key can end a lock, and the hotkey was never
            // registered — or was released — while the app was locked.
            refreshAuthorization()
            return nil
        case let .failure(error):
            return error
        }
    }

    func requestActivation(email: String) async -> ActivationError? {
        guard let entitlementService else { return .notConfigured }
        switch await entitlementService.requestActivation(email: email) {
        case .success:
            refreshAuthorization()
            return nil
        case let .failure(error):
            return error
        }
    }

    func removeLicense() {
        entitlementService?.removeLicense()
    }

    func openCheckout(_ offer: TelemetryEvent.Offer) {
        guard let url = StoreFront.checkoutURL(for: offer) else { return }
        entitlementService?.noteCheckoutOpened(offer)
        StoreFront.open(url)
    }

    // MARK: - Preferences

    var preferencesLocationDescription: String? { preferencesStore?.locationDescription }

    /// Reads the settings file, if there is a store at all.
    ///
    /// A store that cannot be read leaves the defaults in place and records
    /// why in a line the user can see. Refusing to start over a preferences
    /// file would be the app treating its own settings as more important
    /// than the thing it exists to do.
    private func loadPreferences() {
        guard let preferencesStore else { return }
        do {
            apply(try preferencesStore.load())
            preferencesErrorDescription = nil
        } catch {
            preferencesErrorDescription = (error as? PreferencesStoreError)?.message ?? error.localizedDescription
            Log.application.error("Settings load failed: \(self.preferencesErrorDescription ?? "", privacy: .public)")
        }
    }

    private func apply(_ preferences: Preferences) {
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }
        // A stored binding with no modifier could only come from someone
        // editing the file by hand, and registering it would take a bare key
        // away from every application on the Mac.
        if !preferences.hotkeyBinding.modifiers.isEmpty {
            binding = preferences.hotkeyBinding
        }
        activation = preferences.activation
        languageProfile = preferences.languageProfile
        insertsAutomatically = preferences.insertsAutomatically
    }

    private var currentPreferences: Preferences {
        Preferences(
            hotkeyKeyCode: binding.keyCode,
            hotkeyModifiers: binding.modifiers.rawValue,
            hotkeyKeyLabel: binding.keyLabel,
            activation: activation,
            languageProfile: languageProfile,
            insertsAutomatically: insertsAutomatically
        )
    }

    private func persistPreferences() {
        guard let preferencesStore, !isApplyingPreferences else { return }
        do {
            try preferencesStore.save(currentPreferences)
            preferencesErrorDescription = nil
        } catch {
            preferencesErrorDescription = (error as? PreferencesStoreError)?.message ?? error.localizedDescription
            Log.application.error("Settings save failed: \(self.preferencesErrorDescription ?? "", privacy: .public)")
        }
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
        // What the ungated window is spent on: text the user actually got.
        // Counted here, before insertion, because whether the text then lands
        // in a document or on the clipboard is not the user's doing.
        if !result.isEmpty { entitlementService?.recordSuccessfulDictation() }
        diagnostics.lastRisk = RiskDiagnostics(result)
        Log.application.info(
            """
            Result ready: \(result.cleanup.edits.count) edits, \(result.spans.count) spans, \(result.flaggedSpans.count) flagged, \(result.highlightedSpans.count) highlighted, attention \(result.deservesAttention ? "pending" : "none", privacy: .public)
            """
        )

        if result.isEmpty {
            // Nothing to insert and nothing to review, so this notice is the
            // only thing the app will say about a press the user made and
            // heard back nothing from.
            noteSilence(silence(for: transcript))
        }

        if result.deservesAttention {
            // Lit, not shown. The user finds out there is something to check
            // from a triangle they can ignore, and the recording stays alive
            // only because the review they may open needs it.
            attentionIsPending = true
        } else {
            // Nothing worth saying, so the recording's job is over. Releasing
            // here rather than at the end of the interaction is the whole point
            // of deciding early.
            releaseRetainedAudio()
        }

        // Unconditional, and that is the change this phase exists for. Risk
        // marks no longer stand between the user and their own document: the
        // words appear where they were already typing, every time, and the
        // checking is offered afterwards to whoever wants it.
        if insertsAutomatically, performInsertion(of: result.cleanedText) { return }
        apply(.transcriptionFinished)
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

        switch state {
        case .recording:
            // There is speech in the buffer. It ends here — the device it
            // was being recorded from is gone — but it ends the way a
            // released key ends it: the utterance is finished, transcribed,
            // and delivered, and the reason is said afterwards rather than
            // instead. Discarding it was the app taking back words the user
            // had already said, which is the one thing `docs/PHASE_6.md`
            // spends a section refusing to do for a trial that runs out.
            captureInterruption = error
            guard apply(.hotkeyReleased) else { return }
            stopPolling()
            finishCapture(reason: .interrupted)

        case .finishing:
            // A stop is already in flight. The recording is not ended twice,
            // and the reason still reaches the user.
            captureInterruption = error

        default:
            // `.starting`: the engine never opened, so there is nothing to
            // save and the failure is the whole story.
            guard apply(.captureInterrupted(.captureInterrupted(error.message))) else { return }
            stopPolling()
            let wasRunning = captureIsRunning
            captureIsRunning = false
            if wasRunning {
                let service = captureService
                Task { _ = await service.stop(reason: .interrupted) }
            }
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
            // The live engine gets the system dictionaries; the benchmark does
            // not. See `RiskEngine.standard(weights:lexicon:)` for why the
            // measurement deliberately runs without them.
            riskEngine: .standard(lexicon: SystemLexicon()),
            reviewPolicy: .default,
            glossaryStore: FileGlossaryStore(),
            fragmentPlayer: AVAudioEngineFragmentPlayer(),
            accessibilityService: accessibility,
            insertionService: AXTextInsertionService(permissionService: accessibility),
            // The licensing state of this Mac, read from disk and from a
            // signature. `LicenseAuthority.production` is empty in a
            // development build, which means no key verifies and the ungated
            // window is all there is — see `docs/PHASE_6.md`.
            entitlementService: EntitlementService(store: FileEntitlementStore()),
            // The third and last thing this app writes to disk. Everything in
            // it is a choice the user made about the app, and none of it is
            // derived from anything that was said.
            preferencesStore: FilePreferencesStore()
        )
    }
}
