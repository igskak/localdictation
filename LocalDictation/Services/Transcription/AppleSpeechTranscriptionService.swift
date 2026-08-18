import AVFoundation
import Foundation
import Speech

/// Benchmark candidate: Apple's on-device `SFSpeechRecognizer`.
///
/// Chosen as the no-dependency baseline. It ships with macOS, needs no model
/// download, and runs at the 14.4 deployment target. Its weaknesses are exactly
/// what the Phase 2 benchmark exists to measure:
///
/// - one recognizer serves one locale, so a mixed profile is only approximated
///   by its primary language;
/// - `SFTranscriptionSegment.confidence` is frequently reported as `0` for
///   on-device recognition, which would leave Phase 3's risk engine blind.
///
/// Neither weakness is worked around here. The adapter reports what the
/// framework actually returns so the benchmark measures the engine, not a
/// flattering wrapper around it.
final class AppleSpeechTranscriptionService: TranscriptionService {
    let identifier = "apple-speech"
    let displayName = "Apple Speech (on-device)"

    /// `true` keeps recognition local. It is never flipped: sending audio to
    /// Apple's servers would violate the product's core constraint.
    private let requiresOnDeviceRecognition = true

    func supports(_ profile: LanguageProfile) -> Bool {
        guard let recognizer = Self.makeRecognizer(for: profile) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            return .unavailable("Speech recognition access has not been granted yet")
        case .denied:
            return .unavailable("Speech recognition access was denied in System Settings")
        case .restricted:
            return .unavailable("Speech recognition is restricted on this Mac")
        case .authorized:
            break
        @unknown default:
            return .unavailable("Unknown speech recognition authorization state")
        }

        guard let recognizer = Self.makeRecognizer(for: profile) else {
            return .unavailable("\(profile.primary.displayName) is not available on this Mac")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable("\(profile.primary.displayName) has no on-device model installed")
        }
        guard recognizer.isAvailable else {
            return .preparing(progress: nil)
        }
        return .ready
    }

    func prepare(for profile: LanguageProfile) async throws {
        let status = await Self.requestAuthorization()
        switch status {
        case .authorized:
            break
        case .denied:
            throw TranscriptionError.modelUnavailable("Speech recognition access was denied in System Settings")
        case .restricted:
            throw TranscriptionError.modelUnavailable("Speech recognition is restricted on this Mac")
        case .notDetermined:
            throw TranscriptionError.modelUnavailable("Speech recognition access was not granted")
        @unknown default:
            throw TranscriptionError.modelUnavailable("Unknown speech recognition authorization state")
        }

        guard let recognizer = Self.makeRecognizer(for: profile) else {
            throw TranscriptionError.unsupportedProfile(profile)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.modelUnavailable(
                "macOS has no on-device \(profile.primary.displayName) model. Add the language under System Settings → General → Language & Region."
            )
        }
    }

    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript {
        guard !utterance.samples.isEmpty else { throw TranscriptionError.emptyAudio }
        guard let recognizer = Self.makeRecognizer(for: profile) else {
            throw TranscriptionError.unsupportedProfile(profile)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.modelUnavailable("No on-device \(profile.primary.displayName) model is installed")
        }

        let buffer = try Self.makeBuffer(from: utterance)
        let started = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        let words = try await Self.recognize(request: request, using: recognizer)
        let processingDuration = Date().timeIntervalSince(started)

        return Transcript.assemble(
            words: words,
            profile: profile,
            detectedLanguage: profile.primary,
            audioDuration: utterance.duration,
            processingDuration: processingDuration,
            engineIdentifier: identifier
        )
    }

    // MARK: - Framework bridging

    private static func makeRecognizer(for profile: LanguageProfile) -> SFSpeechRecognizer? {
        // `SFSpeechRecognizer` binds to exactly one locale, so a mixed profile
        // runs on its primary language. This is a real limitation of the
        // candidate and is recorded as such in the benchmark.
        SFSpeechRecognizer(locale: Locale(identifier: profile.primary.localeIdentifier))
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func makeBuffer(from utterance: CapturedUtterance) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: utterance.sampleRate,
            channels: AVAudioChannelCount(AudioTargetFormat.channelCount),
            interleaved: false
        ) else {
            throw TranscriptionError.engineFailure("Could not describe the capture format")
        }

        let frameCount = AVAudioFrameCount(utterance.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else {
            throw TranscriptionError.engineFailure("Could not allocate an input buffer")
        }

        utterance.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = frameCount
        return buffer
    }

    /// Bridges the multi-callback recognition task onto a single continuation.
    ///
    /// Segments are mapped to `Transcript.Word` inside the callback so nothing
    /// non-`Sendable` crosses the continuation. The handler can fire more than
    /// once, and cancellation can arrive before the task even exists, so both
    /// paths go through `RecognitionBridge`.
    private static func recognize(
        request: SFSpeechAudioBufferRecognitionRequest,
        using recognizer: SFSpeechRecognizer
    ) async throws -> [Transcript.Word] {
        let bridge = RecognitionBridge()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.attach(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        bridge.fail(TranscriptionError.engineFailure(error.localizedDescription))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    bridge.finish(Self.words(from: result.bestTranscription))
                }
                bridge.setTask(task)
            }
        } onCancel: {
            bridge.cancel()
        }
    }

    private static func words(from transcription: SFTranscription) -> [Transcript.Word] {
        transcription.segments.map { segment in
            Transcript.Word(
                segment.substring,
                start: segment.timestamp,
                end: segment.timestamp + segment.duration,
                // The framework reports 0 both for "certainly wrong" and for
                // "no confidence available". Treating 0 as absent keeps the
                // benchmark from reading a missing signal as a real one.
                confidence: segment.confidence > 0 ? Double(segment.confidence) : nil
            )
        }
    }
}

/// Owns the continuation and the recognition task together, so exactly one of
/// "result", "error", and "cancelled" resumes the caller — regardless of the
/// order in which the framework callback and task cancellation arrive.
private final class RecognitionBridge: @unchecked Sendable {
    private let lock = UnfairLock()
    private var continuation: CheckedContinuation<[Transcript.Word], any Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func attach(_ continuation: CheckedContinuation<[Transcript.Word], any Error>) {
        let alreadyCancelled: Bool = lock.withLock {
            guard !cancelled else { return true }
            self.continuation = continuation
            return false
        }
        if alreadyCancelled {
            continuation.resume(throwing: TranscriptionError.cancelled)
        }
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        let alreadyCancelled: Bool = lock.withLock {
            guard !cancelled else { return true }
            self.task = task
            return false
        }
        if alreadyCancelled {
            task.cancel()
        }
    }

    func finish(_ words: [Transcript.Word]) {
        take()?.resume(returning: words)
    }

    func fail(_ error: any Error) {
        take()?.resume(throwing: error)
    }

    func cancel() {
        let pending: SFSpeechRecognitionTask? = lock.withLock {
            cancelled = true
            let current = task
            task = nil
            return current
        }
        pending?.cancel()
        take()?.resume(throwing: TranscriptionError.cancelled)
    }

    /// Hands the continuation to exactly one caller.
    private func take() -> CheckedContinuation<[Transcript.Word], any Error>? {
        lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
    }
}
