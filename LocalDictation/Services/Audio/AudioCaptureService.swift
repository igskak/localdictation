import Foundation

/// The single normalized capture format for the whole pipeline.
enum AudioTargetFormat {
    static let sampleRate: Double = 16_000
    static let channelCount: Int = 1
}

/// Capture parameters owned by the coordinator. Phase 1 keeps these in memory
/// only: no persistence layer is introduced yet.
struct AudioCaptureConfiguration: Sendable, Equatable {
    var voiceActivity: VoiceActivityConfiguration
    /// Hard ceiling for the in-memory buffer. Derived from the VAD maximum so the
    /// buffer can never grow past one bounded utterance.
    var maximumUtteranceDuration: TimeInterval { voiceActivity.maximumUtteranceDuration }

    static let `default` = AudioCaptureConfiguration(voiceActivity: .default)

    var bufferCapacityFrames: Int {
        max(Int((maximumUtteranceDuration * AudioTargetFormat.sampleRate).rounded()), 1)
    }
}

enum AudioCaptureError: Error, Sendable, Equatable {
    case noInputDevice
    case unsupportedInputFormat(String)
    case converterUnavailable(String)
    case conversionFailed(String)
    case engineStartFailed(String)
    case inputDeviceChanged
    case notRecording

    var message: String {
        switch self {
        case .noInputDevice:
            "No microphone input device is available"
        case let .unsupportedInputFormat(detail):
            "Unsupported input format (\(detail))"
        case let .converterUnavailable(detail):
            "Audio converter unavailable (\(detail))"
        case let .conversionFailed(detail):
            "Audio conversion failed (\(detail))"
        case let .engineStartFailed(detail):
            "Audio engine failed to start (\(detail))"
        case .inputDeviceChanged:
            "The input device changed during recording"
        case .notRecording:
            "No recording is in progress"
        }
    }
}

/// Capture boundary. Implementations must keep audio in a bounded in-memory
/// buffer, must never write to disk, and must not block the real-time callback.
protocol AudioCaptureService: AnyObject, Sendable {
    /// Starts capture. Runs off the main actor in the live implementation.
    func start(
        configuration: AudioCaptureConfiguration,
        onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
    ) async throws -> CaptureFormatDescription

    /// Non-blocking read of live counters, safe to call from the main actor.
    func snapshot() -> CaptureSnapshot

    /// Stops capture and returns the completed utterance, if one was running.
    func stop(reason: UtteranceEndReason) async -> CapturedUtterance?
}
