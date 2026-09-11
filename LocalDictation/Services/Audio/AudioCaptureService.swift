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
            L10n.string("No microphone input device is available")
        case let .unsupportedInputFormat(detail):
            L10n.format("Unsupported input format (%@)", detail)
        case let .converterUnavailable(detail):
            L10n.format("Audio converter unavailable (%@)", detail)
        case let .conversionFailed(detail):
            L10n.format("Audio conversion failed (%@)", detail)
        case let .engineStartFailed(detail):
            L10n.format("Audio engine failed to start (%@)", detail)
        case .inputDeviceChanged:
            L10n.string("The input device changed during recording")
        case .notRecording:
            L10n.string("No recording is in progress")
        }
    }

    /// What to tell the user when this ended a recording they were in the
    /// middle of.
    ///
    /// Separate from `message`, which is a technical description for
    /// diagnostics and logs. This one has a job the other cannot do: say that
    /// the recording stopped *and* that what had already been said was kept,
    /// because otherwise the sentence reads as "your dictation was lost" and
    /// the user starts over on text that is already in their document.
    var interruptionMessage: String {
        switch self {
        case .inputDeviceChanged:
            L10n.string("The microphone changed while you were speaking, so the recording ended there. Whatever you had already said was kept.")
        case .noInputDevice:
            L10n.string("The microphone went away while you were speaking, so the recording ended there. Whatever you had already said was kept.")
        default:
            L10n.format("The recording ended early: %@. Whatever you had already said was kept.", message.lowercased())
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
