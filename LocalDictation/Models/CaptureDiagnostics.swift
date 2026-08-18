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

/// Non-content summary of the last transcript.
///
/// Deliberately counts and timings only. The recognized text itself is never
/// copied into diagnostics, so nothing here can end up in a log line.
struct TranscriptDiagnostics: Sendable, Equatable {
    let engineIdentifier: String
    let profileLabel: String
    let detectedLanguage: String?
    let tokenCount: Int
    let characterCount: Int
    let processingDuration: TimeInterval
    let realTimeFactor: Double?
    let meanConfidence: Double?
    let minimumConfidence: Double?
    let hasConfidenceSignal: Bool

    init(_ transcript: Transcript) {
        engineIdentifier = transcript.engineIdentifier
        profileLabel = transcript.profile.shortLabel
        detectedLanguage = transcript.detectedLanguage?.rawValue
        tokenCount = transcript.tokens.count
        characterCount = transcript.text.count
        processingDuration = transcript.processingDuration
        realTimeFactor = transcript.realTimeFactor
        meanConfidence = transcript.meanConfidence
        minimumConfidence = transcript.minimumConfidence
        hasConfidenceSignal = transcript.hasConfidenceSignal
    }
}

/// Everything the developer diagnostics section displays.
struct CaptureDiagnostics: Sendable, Equatable {
    var format: CaptureFormatDescription?
    var snapshot: CaptureSnapshot = CaptureSnapshot()
    var lastUtterance: UtteranceSummary?
    var lastTranscript: TranscriptDiagnostics?
    var lastErrorDescription: String?

    static let empty = CaptureDiagnostics()
}
