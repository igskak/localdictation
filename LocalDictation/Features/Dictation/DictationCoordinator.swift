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
    @Published private(set) var transcriptionModelState: TranscriptionModelState = .unavailable("No speech engine configured")
    /// Selected language profile. Explicit, never inferred per utterance.
    @Published var languageProfile: LanguageProfile

    let binding: HotkeyBinding

    private let permissionService: any MicrophonePermissionService
    private let hotkeyService: any HotkeyService
    private let captureService: any AudioCaptureService
    private let transcriptionService: (any TranscriptionService)?

    private var machine = RecordingStateMachine()
    private var pollTimer: Timer?
    private var captureIsRunning = false
    private var pendingEndReason: UtteranceEndReason?
    private let pollInterval: TimeInterval
    private var transcriptionTask: Task<Void, Never>?
    /// Incremented whenever a transcription is started or superseded. A result
    /// carrying a stale generation is dropped instead of being published.
    private var transcriptionGeneration = 0

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
        configuration: AudioCaptureConfiguration = .default,
        binding: HotkeyBinding = .optionSpace,
        languageProfile: LanguageProfile = .default,
        pollInterval: TimeInterval = 0.1
    ) {
        self.permissionService = permissionService
        self.hotkeyService = hotkeyService
        self.captureService = captureService
        self.transcriptionService = transcriptionService
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
        apply(.authorizationResolved(permissionService.currentAuthorization))
        registerHotkey()
    }

    func deactivate() {
        stopPolling()
        cancelTranscription()
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

        // A new utterance supersedes whatever is still being transcribed, and
        // clears the previous transcript so the copy action is never ambiguous
        // about which utterance it belongs to.
        cancelTranscription()
        transcript = nil
        pendingEndReason = nil
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
            #if DEBUG
            lastUtteranceSamples = utterance.samples
            #endif
            Log.audio.info(
                "Utterance completed: \(String(format: "%.2f", summary.duration)) s at \(Int(summary.sampleRate)) Hz, dropped \(summary.droppedFrameCount), reason \(summary.endReason.rawValue, privacy: .public)"
            )
        }

        apply(.utteranceCompleted)

        if let utterance {
            startTranscription(for: utterance)
        }
    }

    // MARK: - Transcription

    /// Explicit user action: load or download the engine's model.
    func prepareTranscriptionModel() async {
        guard let transcriptionService else { return }
        let profile = languageProfile
        transcriptionModelState = .preparing(progress: nil)
        do {
            try await transcriptionService.prepare(for: profile)
            transcriptionModelState = await transcriptionService.modelState(for: profile)
        } catch {
            let message = (error as? TranscriptionError)?.message ?? error.localizedDescription
            Log.transcription.error("Model preparation failed: \(message, privacy: .public)")
            transcriptionModelState = .failed(message)
        }
    }

    func refreshTranscriptionModelState() async {
        guard let transcriptionService else { return }
        transcriptionModelState = await transcriptionService.modelState(for: languageProfile)
    }

    func clearTranscript() {
        transcript = nil
    }

    private func startTranscription(for utterance: CapturedUtterance) {
        guard let transcriptionService else { return }
        guard !utterance.samples.isEmpty else { return }

        let profile = languageProfile
        guard transcriptionService.supports(profile) else {
            guard apply(.transcriptionStarted) else { return }
            apply(.transcriptionFailed(TranscriptionError.unsupportedProfile(profile).message))
            return
        }
        guard apply(.transcriptionStarted) else { return }

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
    }

    /// Drops the in-flight request and invalidates its generation, so a result
    /// already in flight cannot land after the caller moved on.
    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionGeneration += 1
    }

    private func transcriptionDidFinish(_ result: Transcript, generation: Int) {
        guard generation == transcriptionGeneration else { return }
        transcriptionTask = nil
        transcript = result
        diagnostics.lastTranscript = TranscriptDiagnostics(result)
        Log.transcription.info(
            """
            Transcript ready: engine \(result.engineIdentifier, privacy: .public),             profile \(result.profile.shortLabel, privacy: .public),             \(result.tokens.count) tokens, \(String(format: "%.2f", result.processingDuration)) s inference
            """
        )
        apply(.transcriptionFinished)
    }

    private func transcriptionDidFail(_ message: String, generation: Int) {
        guard generation == transcriptionGeneration else { return }
        transcriptionTask = nil
        diagnostics.lastErrorDescription = message
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
        DictationCoordinator(
            permissionService: AVCaptureMicrophonePermissionService(),
            hotkeyService: CarbonHotkeyService(),
            captureService: AVAudioEngineCaptureService(),
            // Development default rather than a final decision: WhisperKit is
            // the only admitted candidate that returns per-token confidence,
            // which Phase 3 requires. `AppleSpeechTranscriptionService` stays in
            // the codebase as the comparison the benchmark scores it against.
            transcriptionService: WhisperKitTranscriptionService()
        )
    }
}
