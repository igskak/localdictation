import Foundation

/// Description of an active or last-used capture session. Every field is
/// non-content technical metadata.
struct CaptureFormatDescription: Sendable, Equatable {
    var inputDeviceName: String?
    var inputSampleRate: Double
    var inputChannelCount: Int
    var outputSampleRate: Double
    var outputChannelCount: Int
    var bufferCapacityFrames: Int

    var inputDescription: String {
        let device = inputDeviceName ?? "Unknown input device"
        return "\(device) · \(Int(inputSampleRate.rounded())) Hz · \(inputChannelCount) ch"
    }

    var outputDescription: String {
        "\(Int(outputSampleRate.rounded())) Hz · \(outputChannelCount == 1 ? "mono" : "\(outputChannelCount) ch") · Float32"
    }
}

/// Live capture counters read by the UI while recording.
struct CaptureSnapshot: Sendable, Equatable {
    var frameCount: Int = 0
    var capacityFrames: Int = 0
    var peakLevel: Float = 0
    var droppedFrameCount: Int = 0
    var voiceActivity: VoiceActivityObservation = .initial
    var sampleRate: Double = AudioTargetFormat.sampleRate

    var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    var utilization: Double { capacityFrames > 0 ? Double(frameCount) / Double(capacityFrames) : 0 }
    var reachedCapacity: Bool { capacityFrames > 0 && frameCount >= capacityFrames }
}

/// Everything the developer diagnostics section displays.
struct CaptureDiagnostics: Sendable, Equatable {
    var format: CaptureFormatDescription?
    var snapshot: CaptureSnapshot = CaptureSnapshot()
    var lastUtterance: UtteranceSummary?
    var lastErrorDescription: String?

    static let empty = CaptureDiagnostics()
}
