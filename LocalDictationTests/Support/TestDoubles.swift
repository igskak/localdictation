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
