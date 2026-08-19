import Foundation
@testable import LocalDictation

/// Permission service that never touches AVFoundation, so tests can exercise
/// every authorization state without a system dialog.
final class FakeMicrophonePermissionService: MicrophonePermissionService, @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: MicrophoneAuthorization
    private var requestResult: MicrophoneAuthorization
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(authorization: MicrophoneAuthorization, requestResult: MicrophoneAuthorization = .authorized) {
        self.authorization = authorization
        self.requestResult = requestResult
    }

    var currentAuthorization: MicrophoneAuthorization {
        lock.withLock { authorization }
    }

    func set(_ authorization: MicrophoneAuthorization) {
        lock.withLock { self.authorization = authorization }
    }

    func requestAccess() async -> MicrophoneAuthorization {
        lock.withLock {
            requestCount += 1
            authorization = requestResult
            return authorization
        }
    }

    @MainActor
    func openSystemSettings() {
        lock.withLock { openSettingsCount += 1 }
    }
}

/// Hotkey service that records registration and lets tests emit press/release.
final class FakeHotkeyService: HotkeyService, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HotkeyEvent) -> Void)?
    private var binding: HotkeyBinding?
    private var registrationError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(registrationError: (any Error)? = nil) {
        self.registrationError = registrationError
    }

    var registeredBinding: HotkeyBinding? {
        lock.withLock { binding }
    }

    func failRegistration(with error: any Error) {
        lock.withLock { registrationError = error }
    }

    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        let error: (any Error)? = lock.withLock {
            registerCount += 1
            return registrationError
        }
        if let error { throw error }
        lock.withLock {
            self.binding = binding
            self.handler = handler
        }
    }

    func unregister() {
        lock.withLock {
            unregisterCount += 1
            binding = nil
            handler = nil
        }
    }

    /// Emits an event the way the Carbon service does: synchronously on the main thread.
    @MainActor
    func emit(_ event: HotkeyEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }
}

/// Capture service backed by canned data. It performs no audio I/O and no file I/O.
final class FakeAudioCaptureService: AudioCaptureService, @unchecked Sendable {
    private let lock = NSLock()

    private var startError: AudioCaptureError?
    private var startDelayNanoseconds: UInt64 = 0
    private var snapshotValue = CaptureSnapshot(
        frameCount: 8_000,
        capacityFrames: 1_920_000,
        peakLevel: 0.42,
        droppedFrameCount: 0,
        voiceActivity: .initial,
        sampleRate: AudioTargetFormat.sampleRate
    )
    private var interruptionHandler: (@Sendable (AudioCaptureError) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopReasons: [UtteranceEndReason] = []

    var formatDescription = CaptureFormatDescription(
        inputDeviceName: "Fake Input",
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        outputSampleRate: AudioTargetFormat.sampleRate,
        outputChannelCount: AudioTargetFormat.channelCount,
        bufferCapacityFrames: 1_920_000
    )

    func failNextStart(with error: AudioCaptureError) {
        lock.withLock { startError = error }
    }

    func delayStart(nanoseconds: UInt64) {
        lock.withLock { startDelayNanoseconds = nanoseconds }
    }

    func setSnapshot(_ snapshot: CaptureSnapshot) {
        lock.withLock { snapshotValue = snapshot }
    }

    func triggerInterruption(_ error: AudioCaptureError) {
        let handler = lock.withLock { interruptionHandler }
        handler?(error)
    }

    func start(
        configuration: AudioCaptureConfiguration,
        onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
    ) async throws -> CaptureFormatDescription {
        let (error, delay): (AudioCaptureError?, UInt64) = lock.withLock {
            startCount += 1
            interruptionHandler = onInterruption
            let error = startError
            startError = nil
            return (error, startDelayNanoseconds)
        }

        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        if let error { throw error }
        return lock.withLock { formatDescription }
    }

    func snapshot() -> CaptureSnapshot {
        lock.withLock { snapshotValue }
    }

    func stop(reason: UtteranceEndReason) async -> CapturedUtterance? {
        let snapshot: CaptureSnapshot = lock.withLock {
            stopCount += 1
            stopReasons.append(reason)
            interruptionHandler = nil
            return snapshotValue
        }

        return CapturedUtterance(
            samples: [Float](repeating: 0.1, count: min(snapshot.frameCount, 16_000)),
            sampleRate: AudioTargetFormat.sampleRate,
            peakLevel: snapshot.peakLevel,
            droppedFrameCount: snapshot.droppedFrameCount,
            voiceActivity: snapshot.voiceActivity,
            endReason: reason
        )
    }
}

/// Transcription service backed by canned results. It loads no model, touches
/// no framework, and can be told to block so tests can supersede a request that
/// is still in flight.
final class FakeTranscriptionService: TranscriptionService, @unchecked Sendable {
    let identifier = "fake"
    let displayName = "Fake Engine"

    private let lock = NSLock()
    private var result: Transcript?
    private var error: TranscriptionError?
    private var unsupportedProfiles: Set<LanguageProfile> = []
    private var state: TranscriptionModelState = .ready
    private var gate: AsyncGate?
    private var prepareGate: AsyncGate?
    private var prepareError: TranscriptionError?

    private(set) var transcribeCount = 0
    private(set) var prepareCount = 0
    private(set) var requestedProfiles: [LanguageProfile] = []
    private(set) var cancelledCount = 0

    func setResult(_ transcript: Transcript) {
        lock.withLock { result = transcript; error = nil }
    }

    func setError(_ error: TranscriptionError) {
        lock.withLock { self.error = error; result = nil }
    }

    func setModelState(_ state: TranscriptionModelState) {
        lock.withLock { self.state = state }
    }

    func failPreparation(with error: TranscriptionError) {
        lock.withLock { prepareError = error }
    }

    func markUnsupported(_ profile: LanguageProfile) {
        lock.withLock { _ = unsupportedProfiles.insert(profile) }
    }

    /// Makes the next `transcribe` block until the returned gate is opened.
    func blockNextTranscription() -> AsyncGate {
        let gate = AsyncGate()
        lock.withLock { self.gate = gate }
        return gate
    }

    /// Makes the next `prepare` block until the returned gate is opened, so a
    /// test can observe the model state while a load is genuinely in flight.
    func blockNextPreparation() -> AsyncGate {
        let gate = AsyncGate()
        lock.withLock { self.prepareGate = gate }
        return gate
    }

    func supports(_ profile: LanguageProfile) -> Bool {
        lock.withLock { !unsupportedProfiles.contains(profile) }
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        lock.withLock { state }
    }

    func prepare(for profile: LanguageProfile) async throws {
        let (error, gate): (TranscriptionError?, AsyncGate?) = lock.withLock {
            prepareCount += 1
            let gate = prepareGate
            prepareGate = nil
            return (prepareError, gate)
        }
        if let gate { try await gate.wait() }
        if let error { throw error }
        lock.withLock { state = .ready }
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        let gate: AsyncGate? = lock.withLock {
            transcribeCount += 1
            requestedProfiles.append(profile)
            let gate = self.gate
            self.gate = nil
            return gate
        }

        if let gate {
            do {
                try await gate.wait()
            } catch {
                lock.withLock { cancelledCount += 1 }
                throw TranscriptionError.cancelled
            }
        }

        try Task.checkCancellation()

        let (result, error): (Transcript?, TranscriptionError?) = lock.withLock { (self.result, self.error) }
        if let error { throw error }
        guard let result else { throw TranscriptionError.engineFailure("No canned result configured") }
        return result
    }
}

/// A suspension point a test can open explicitly, so "still running" is a real
/// state rather than a race against a sleep.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var opened = false

    func open() {
        let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
            opened = true
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume()
    }

    func wait() async throws {
        if lock.withLock({ opened }) { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyOpen: Bool = lock.withLock {
                    guard !opened else { return true }
                    self.continuation = continuation
                    return false
                }
                if alreadyOpen { continuation.resume() }
            }
        } onCancel: {
            let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
                let current = continuation
                continuation = nil
                return current
            }
            pending?.resume(throwing: CancellationError())
        }
    }
}

extension Transcript {
    /// Convenience builder for tests: words with uniform timing.
    static func fixture(
        words: [(String, Double?)],
        profile: LanguageProfile = .default,
        engineIdentifier: String = "fake",
        audioDuration: TimeInterval = 1,
        processingDuration: TimeInterval = 0.1
    ) -> Transcript {
        let timed = words.enumerated().map { index, entry in
            Transcript.Word(
                entry.0,
                start: Double(index) * 0.1,
                end: Double(index) * 0.1 + 0.1,
                confidence: entry.1
            )
        }
        return .assemble(
            words: timed,
            profile: profile,
            audioDuration: audioDuration,
            processingDuration: processingDuration,
            engineIdentifier: engineIdentifier
        )
    }
}

/// Fragment player that records what it was asked to play and never touches
/// AVAudioEngine, so replay can be asserted without a sound device.
@MainActor
final class FakeAudioFragmentPlayer: AudioFragmentPlayer {
    private(set) var isPlaying = false
    private(set) var playedFragments: [(samples: [Float], sampleRate: Double)] = []
    private(set) var stopCount = 0
    var errorToThrow: AudioPlaybackError?

    var playCount: Int { playedFragments.count }
    var lastFrameCount: Int { playedFragments.last?.samples.count ?? 0 }

    func play(samples: [Float], sampleRate: Double) throws {
        if let errorToThrow { throw errorToThrow }
        playedFragments.append((samples, sampleRate))
        isPlaying = true
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }
}

/// Glossary store backed by memory, so coordinator tests never write to the
/// real Application Support directory.
final class InMemoryGlossaryStore: GlossaryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Glossary
    private var loadError: GlossaryStoreError?
    private var saveError: GlossaryStoreError?
    private(set) var saveCount = 0

    init(_ glossary: Glossary = .empty) {
        stored = glossary
    }

    var locationDescription: String { "in memory" }

    var current: Glossary { lock.withLock { stored } }

    func failLoad(with error: GlossaryStoreError) {
        lock.withLock { loadError = error }
    }

    func failSave(with error: GlossaryStoreError) {
        lock.withLock { saveError = error }
    }

    func load() throws -> Glossary {
        let (error, glossary): (GlossaryStoreError?, Glossary) = lock.withLock { (loadError, stored) }
        if let error { throw error }
        return glossary
    }

    func save(_ glossary: Glossary) throws {
        let error: GlossaryStoreError? = lock.withLock {
            saveCount += 1
            return saveError
        }
        if let error { throw error }
        lock.withLock { stored = glossary }
    }
}

/// Cleanup double that returns whatever a test needs, so the coordinator and
/// the risk engine can be exercised without the real rule set.
struct StubCleanupService: CleanupService {
    let result: CleanupResult

    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult {
        result
    }
}

/// Signal double producing fixed spans, so `RiskEngine` can be tested for what
/// it does — weighting, mapping, deduplication — rather than for what the real
/// signals find.
struct StubRiskSignal: RiskSignal {
    let identifier: String
    let produced: [RawRiskSpan]

    init(identifier: String = "stub", produced: [RawRiskSpan]) {
        self.identifier = identifier
        self.produced = produced
    }

    func spans(in context: RiskContext) -> [RawRiskSpan] { produced }
}

extension Transcript {
    /// A transcript whose tokens carry the character ranges of `text`, built by
    /// scanning it. Used where a test needs timings that line up with a
    /// specific string rather than with a list of words.
    static func fixture(
        text: String,
        profile: LanguageProfile = .default,
        confidence: Double? = 0.9,
        secondsPerWord: TimeInterval = 0.4,
        engineIdentifier: String = "fake"
    ) -> Transcript {
        let words = WordScanner.words(in: text)
        let tokens = words.map { word in
            TranscriptToken(
                text: word.text,
                range: word.range,
                start: Double(word.index) * secondsPerWord,
                end: Double(word.index + 1) * secondsPerWord,
                confidence: confidence
            )
        }
        return Transcript(
            text: text,
            tokens: tokens,
            profile: profile,
            detectedLanguage: nil,
            audioDuration: Double(max(words.count, 1)) * secondsPerWord,
            processingDuration: 0.1,
            engineIdentifier: engineIdentifier
        )
    }
}

/// Accessibility trust that answers from a variable instead of from macOS, so
/// tests can run both sides of the trust boundary without a system prompt.
final class FakeAccessibilityPermissionService: AccessibilityPermissionService, @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: AccessibilityAuthorization
    private var trustAfterRequest: AccessibilityAuthorization
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(
        authorization: AccessibilityAuthorization = .trusted,
        trustAfterRequest: AccessibilityAuthorization? = nil
    ) {
        self.authorization = authorization
        self.trustAfterRequest = trustAfterRequest ?? authorization
    }

    var currentAuthorization: AccessibilityAuthorization {
        lock.withLock { authorization }
    }

    func set(_ authorization: AccessibilityAuthorization) {
        lock.withLock { self.authorization = authorization }
    }

    func requestTrust() -> AccessibilityAuthorization {
        lock.withLock {
            requestCount += 1
            authorization = trustAfterRequest
            return authorization
        }
    }

    @MainActor
    func openSystemSettings() {
        lock.withLock { openSettingsCount += 1 }
    }
}

/// Insertion service that records what it was asked to insert and where,
/// without an Accessibility call, a synthetic key event, or a write to the
/// user's real pasteboard.
@MainActor
final class FakeTextInsertionService: TextInsertionService {
    struct Attempt: Equatable {
        let text: String
        let target: InsertionTarget?
    }

    /// What `captureTarget()` hands back. `nil` models dictating with no other
    /// application in front.
    var targetToCapture: InsertionTarget? = InsertionTarget(
        processIdentifier: 501,
        bundleIdentifier: "com.example.editor",
        applicationName: "Editor"
    )
    var outcome: InsertionOutcome = .inserted(.focusedElement)
    /// Held open to model the paste path's settling delay, so a test can press
    /// the hotkey while an insertion is still in flight.
    var gate: AsyncGate?

    private(set) var attempts: [Attempt] = []
    private(set) var captureCount = 0

    var insertCount: Int { attempts.count }
    var lastAttempt: Attempt? { attempts.last }
    var insertedText: String? { attempts.last?.text }

    func captureTarget() -> InsertionTarget? {
        captureCount += 1
        return targetToCapture
    }

    func insert(_ text: String, into target: InsertionTarget?) async -> InsertionOutcome {
        attempts.append(Attempt(text: text, target: target))
        if let gate { try? await gate.wait() }
        return outcome
    }
}
