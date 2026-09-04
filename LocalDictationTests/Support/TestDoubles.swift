import CryptoKit
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
    private var oneShotError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var registeredBindings: [HotkeyBinding] = []

    init(registrationError: (any Error)? = nil) {
        self.registrationError = registrationError
    }

    var registeredBinding: HotkeyBinding? {
        lock.withLock { binding }
    }

    func failRegistration(with error: any Error) {
        lock.withLock { registrationError = error }
    }

    /// Fails exactly one registration, so a test can watch the app refuse a
    /// combination and put the working one back — which needs the second
    /// registration to succeed.
    func failNextRegistration(with error: any Error) {
        lock.withLock { oneShotError = error }
    }

    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        let error: (any Error)? = lock.withLock {
            registerCount += 1
            registeredBindings.append(binding)
            if let oneShot = oneShotError {
                oneShotError = nil
                return oneShot
            }
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

/// The frontmost application, scripted read by read.
///
/// A target that disappears behind a system panel and comes back is the case
/// worth testing, and it cannot be staged against the real window server: the
/// panels that do it — a screen lock, a Touch ID sheet, `loginwindow` — are not
/// summonable from a test.
@MainActor
final class FakeFrontmostApplicationSource: FrontmostApplicationSource {
    /// One entry per read. The last entry answers every read after it, so a
    /// short script stands for a steady state.
    var reads: [FrontmostApplication?]
    private(set) var readCount = 0

    init(_ reads: [FrontmostApplication?]) {
        self.reads = reads
    }

    var frontmostApplication: FrontmostApplication? {
        defer { readCount += 1 }
        guard !reads.isEmpty else { return nil }
        return readCount < reads.count ? reads[readCount] : reads[reads.count - 1]
    }
}

/// The pasteboard, in memory, so no test writes to the user's clipboard.
/// The login-item registration, scripted.
///
/// The real one writes to the user's login items and refuses outright for a
/// build running from Xcode, so neither of its interesting answers can be
/// produced by a test that uses it.
@MainActor
final class FakeLoginItemService: LoginItemService {
    private(set) var state: LoginItemState
    private(set) var calls: [Bool] = []
    private(set) var openedSystemSettings = 0
    private var refusal: String?

    init(_ state: LoginItemState = .disabled) {
        self.state = state
    }

    func refuse(with reason: String) {
        refusal = reason
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemState {
        calls.append(enabled)
        if let refusal {
            state = .unavailable(refusal)
            return state
        }
        state = enabled ? .enabled : .disabled
        return state
    }

    func openSystemSettings() {
        openedSystemSettings += 1
    }
}

/// Secure input, scripted.
///
/// The real flag can only be raised by focusing a password field or by an
/// application that leaves it on, and neither can be arranged from a test — so
/// the one refusal the user is most likely to meet would otherwise be the one
/// behaviour with no coverage at all.
@MainActor
final class FakeSecureInputSource: SecureInputSource {
    var secureInputState: SecureInputState

    init(_ state: SecureInputState = .off) {
        secureInputState = state
    }
}

@MainActor
final class FakePasteboard: Pasteboard {
    private(set) var contents: String?
    private(set) var writes: [String] = []
    private(set) var restoreCount = 0
    var changeCount = 0

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(string: contents, changeCount: changeCount)
    }

    @discardableResult
    func write(_ string: String) -> Int {
        contents = string
        writes.append(string)
        changeCount += 1
        return changeCount
    }

    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) {
        guard changeCount == expected else { return }
        restoreCount += 1
        contents = snapshot.string
        changeCount += 1
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

// MARK: - Licensing

/// Usage record in memory, so no test writes into Application Support.
final class InMemoryEntitlementStore: EntitlementStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: UsageRecord?
    private(set) var saveCount = 0
    private var failure: EntitlementStoreError?

    init(_ record: UsageRecord? = nil) {
        self.record = record
    }

    var stored: UsageRecord? { lock.withLock { record } }

    func failNextSaves(with error: EntitlementStoreError) {
        lock.withLock { failure = error }
    }

    func load() throws -> UsageRecord? { lock.withLock { record } }

    func save(_ record: UsageRecord) throws {
        try lock.withLock {
            if let failure { throw failure }
            self.record = record
            saveCount += 1
        }
    }

    var locationDescription: String { "in memory" }
}

struct FixedDeviceIdentity: DeviceIdentityProviding {
    let deviceID: String

    init(_ deviceID: String = "test-device-0001") {
        self.deviceID = deviceID
    }
}

/// Activation service that answers however a test wants it to.
final class FakeActivationBackend: ActivationBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, ActivationError>
    private(set) var requestCount = 0
    private(set) var lastEmail: String?
    private(set) var lastDeviceID: String?
    let isConfigured: Bool

    init(isConfigured: Bool = true, result: Result<String, ActivationError> = .failure(.notConfigured)) {
        self.isConfigured = isConfigured
        self.result = result
    }

    func setResult(_ result: Result<String, ActivationError>) {
        lock.withLock { self.result = result }
    }

    func requestKey(email: String, deviceID: String) async throws -> String {
        try lock.withLock {
            requestCount += 1
            lastEmail = email
            lastDeviceID = deviceID
            return try result.get()
        }
    }

    // MARK: - Releasing a Mac

    private var releaseError: ActivationError?
    private(set) var releaseCount = 0
    private(set) var releasedKey: String?
    private(set) var releasedDeviceID: String?

    func setReleaseError(_ error: ActivationError?) {
        lock.withLock { releaseError = error }
    }

    /// Whether the stub reports a slot as actually freed.
    var releaseFreedASlot = true

    func releaseDevice(key: String, deviceID: String) async throws -> Bool {
        try lock.withLock {
            releaseCount += 1
            releasedKey = key
            releasedDeviceID = deviceID
            if let releaseError { throw releaseError }
            return releaseFreedASlot
        }
    }
}

/// Collects the product events instead of sending them, which is also what the
/// shipping service does — see `LocalOnlyTelemetryService`.
final class RecordingTelemetryService: ProductTelemetryService, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEvent] = []

    var recorded: [TelemetryEvent] { lock.withLock { events } }
    var names: [String] { recorded.map(\.name) }

    func send(_ event: TelemetryEvent) {
        lock.withLock { events.append(event) }
    }
}

/// Issues keys the way the real issuer will, so the verification tests exercise
/// the shipping code path rather than a second implementation of it.
enum TestLicenseIssuer {
    static func makeAuthority() -> (LicenseAuthority, Curve25519.Signing.PrivateKey) {
        let signingKey = Curve25519.Signing.PrivateKey()
        return (LicenseAuthority(publicKey: signingKey.publicKey), signingKey)
    }

    static func issue(
        kind: LicenseKind,
        deviceID: String = "test-device-0001",
        email: String = "owner@example.com",
        issuedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        expiresAt: Date?,
        signingKey: Curve25519.Signing.PrivateKey,
        id: String = "lic_test"
    ) throws -> String {
        try LicenseKey.issue(
            id: id,
            email: email,
            kind: kind,
            deviceID: deviceID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signingKey: signingKey
        )
    }
}
