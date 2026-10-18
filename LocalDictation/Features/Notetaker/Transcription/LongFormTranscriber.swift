import Foundation

struct MeetingRecognitionAudio: Sendable {
    let source: MeetingAudioSource
    let startFrame: Int64
    let samples: [Float]
    var endFrame: Int64 { startFrame + Int64(samples.count) }
}

enum LongFormTranscriptionError: Error, Equatable {
    case invalidFormat
    case missingAudio
    case backlogFull
    case alreadyProcessing
    case modelNotReady
}

/// One source is windowed independently. On a gap, processing stops rather
/// than inventing silence or treating the surviving audio as complete.
struct MeetingWindowBuilder {
    let source: MeetingAudioSource
    let windowFrames: Int
    let overlapFrames: Int
    private var startFrame: Int64?
    private var samples: [Float] = []
    private var hasEmittedWindow = false

    init(source: MeetingAudioSource, windowFrames: Int = 400_000, overlapFrames: Int = 32_000) {
        precondition(windowFrames > 0 && overlapFrames >= 0 && overlapFrames < windowFrames)
        self.source = source
        self.windowFrames = windowFrames
        self.overlapFrames = overlapFrames
    }

    mutating func append(_ chunk: MeetingAudioChunk) throws -> [MeetingRecognitionAudio] {
        guard chunk.source == source, chunk.sampleRate == 16_000, chunk.samples.count <= windowFrames else { throw LongFormTranscriptionError.invalidFormat }
        if let startFrame {
            let expected = startFrame + Int64(samples.count)
            guard abs(chunk.startFrame - expected) <= 2 else { throw LongFormTranscriptionError.missingAudio }
        } else {
            startFrame = chunk.startFrame
        }
        samples.append(contentsOf: chunk.samples)
        var result: [MeetingRecognitionAudio] = []
        while samples.count >= windowFrames, let start = startFrame {
            result.append(MeetingRecognitionAudio(source: source, startFrame: start, samples: Array(samples.prefix(windowFrames))))
            let advance = windowFrames - overlapFrames
            samples.removeFirst(advance)
            startFrame = start + Int64(advance)
            hasEmittedWindow = true
        }
        return result
    }

    mutating func finish() -> MeetingRecognitionAudio? {
        guard let startFrame, !samples.isEmpty,
              !hasEmittedWindow || samples.count > overlapFrames else { return nil }
        let result = MeetingRecognitionAudio(source: source, startFrame: startFrame, samples: samples)
        samples = []
        self.startFrame = nil
        return result
    }
}

struct LongFormMetrics: Sendable {
    var inferenceSeconds: Double = 0
    var maximumQueueDelay: Double = 0
    var peakQueuedWindows: Int = 0
}

private struct QueuedMeetingWindow: Sendable {
    let audio: MeetingRecognitionAudio
    let enqueuedAt: TimeInterval
}

/// The in-flight call remains in the bounded queue until it succeeds. Calls to
/// drainOne are serialized even though actor methods can re-enter at awaits.
actor LongFormTranscriber {
    private let engine: any TranscriptionService
    private let profile: LanguageProfile
    private let capacity: Int
    private var queues: [MeetingAudioSource: [QueuedMeetingWindow]] = [.microphone: [], .system: []]
    private var lastSource: MeetingAudioSource = .system
    private var processing = false
    private(set) var assembler = MeetingTranscriptAssembler()
    private(set) var metrics = LongFormMetrics()

    init(engine: any TranscriptionService, profile: LanguageProfile, capacity: Int = 8) {
        precondition(capacity > 0)
        self.engine = engine
        self.profile = profile
        self.capacity = capacity
    }

    func enqueue(_ window: MeetingRecognitionAudio) throws {
        guard queues.values.reduce(0, { $0 + $1.count }) < capacity else { throw LongFormTranscriptionError.backlogFull }
        queues[window.source, default: []].append(QueuedMeetingWindow(audio: window, enqueuedAt: ProcessInfo.processInfo.systemUptime))
        metrics.peakQueuedWindows = max(metrics.peakQueuedWindows, queues.values.reduce(0) { $0 + $1.count })
    }

    func drainOne() async throws -> Bool {
        guard !processing else { throw LongFormTranscriptionError.alreadyProcessing }
        let preferred: MeetingAudioSource = lastSource == .system ? .microphone : .system
        let alternate: MeetingAudioSource = preferred == .system ? .microphone : .system
        let source = !(queues[preferred] ?? []).isEmpty ? preferred : alternate
        guard let queued = queues[source]?.first else { return false }
        let window = queued.audio
        processing = true
        defer { processing = false }
        guard await engine.modelState(for: profile).isReady else { throw LongFormTranscriptionError.modelNotReady }
        let utterance = CapturedUtterance(samples: window.samples, sampleRate: 16_000, peakLevel: 0,
                                          droppedFrameCount: 0, voiceActivity: .initial, endReason: .hotkeyRelease)
        let started = ProcessInfo.processInfo.systemUptime
        metrics.maximumQueueDelay = max(metrics.maximumQueueDelay, started - queued.enqueuedAt)
        let transcript = try await engine.transcribe(utterance, profile: profile)
        metrics.inferenceSeconds += ProcessInfo.processInfo.systemUptime - started
        queues[source]?.removeFirst()
        lastSource = source
        assembler.append(MeetingTranscriptWindow(source: source, startFrame: window.startFrame,
                                                endFrame: window.endFrame, transcript: transcript))
        return true
    }

    func queuedCount() -> Int { queues.values.reduce(0) { $0 + $1.count } }
}
