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
    case cancelled
}

/// One source is windowed independently. A process tap can be sparse while its
/// app is silent and macOS may delay microphone delivery during system UI such
/// as screenshots. A forward gap closes the current window and starts another
/// at the real host-time position. No silence is invented.
struct MeetingWindowBuilder {
    let source: MeetingAudioSource
    let windowFrames: Int
    let overlapFrames: Int
    let initialWindowFrames: Int
    private var startFrame: Int64?
    private var samples: [Float] = []
    private var hasEmittedWindow = false

    /// Live recognition answers after eight seconds, then uses twelve seconds
    /// of context with a four-second overlap. This keeps first-result latency
    /// unchanged while giving every later boundary enough left context to
    /// avoid decoding a clipped phrase as an unrelated short utterance.
    init(source: MeetingAudioSource) {
        self.init(source: source, windowFrames: 192_000, overlapFrames: 64_000, initialWindowFrames: 128_000)
    }

    /// Explicit sizes keep deterministic tests and probes independent of the
    /// production live-window policy.
    init(source: MeetingAudioSource, windowFrames: Int, overlapFrames: Int) {
        self.init(source: source, windowFrames: windowFrames, overlapFrames: overlapFrames,
                  initialWindowFrames: windowFrames)
    }

    init(source: MeetingAudioSource, windowFrames: Int, overlapFrames: Int, initialWindowFrames: Int) {
        precondition(windowFrames > 0 && overlapFrames >= 0 && overlapFrames < initialWindowFrames
                     && initialWindowFrames <= windowFrames)
        self.source = source
        self.windowFrames = windowFrames
        self.overlapFrames = overlapFrames
        self.initialWindowFrames = initialWindowFrames
    }

    mutating func append(_ chunk: MeetingAudioChunk) throws -> [MeetingRecognitionAudio] {
        guard chunk.source == source, chunk.sampleRate == 16_000, chunk.samples.count <= windowFrames else { throw LongFormTranscriptionError.invalidFormat }
        var result: [MeetingRecognitionAudio] = []
        if let startFrame {
            let expected = startFrame + Int64(samples.count)
            let delta = chunk.startFrame - expected
            if abs(delta) > 2 {
                guard delta > 0 else { throw LongFormTranscriptionError.missingAudio }
                if let window = flush() { result.append(window) }
                self.startFrame = chunk.startFrame
            }
        } else {
            startFrame = chunk.startFrame
        }
        samples.append(contentsOf: chunk.samples)
        while let start = startFrame {
            let requiredFrames = hasEmittedWindow ? windowFrames : initialWindowFrames
            guard samples.count >= requiredFrames else { break }
            result.append(MeetingRecognitionAudio(source: source, startFrame: start,
                                                  samples: Array(samples.prefix(requiredFrames))))
            let advance = requiredFrames - overlapFrames
            samples.removeFirst(advance)
            startFrame = start + Int64(advance)
            hasEmittedWindow = true
        }
        return result
    }

    mutating func finish() -> MeetingRecognitionAudio? {
        flush()
    }

    private mutating func flush() -> MeetingRecognitionAudio? {
        let result: MeetingRecognitionAudio?
        if let startFrame, !samples.isEmpty,
           !hasEmittedWindow || samples.count > overlapFrames {
            result = MeetingRecognitionAudio(source: source, startFrame: startFrame, samples: samples)
        } else {
            result = nil
        }
        samples = []
        startFrame = nil
        hasEmittedWindow = false
        return result
    }
}

struct MeetingSpeechDetector: Sendable {
    let configuration: VoiceActivityConfiguration

    /// Only skip near-digital silence. A false positive merely spends model
    /// time; a false negative would silently discard quiet speech.
    static var conservativeConfiguration: VoiceActivityConfiguration {
        var configuration = VoiceActivityConfiguration.default
        configuration.speechThreshold = 0.0005
        configuration.silenceThreshold = 0.0001
        return configuration
    }

    init(configuration: VoiceActivityConfiguration = MeetingSpeechDetector.conservativeConfiguration) {
        self.configuration = configuration
    }

    func containsSpeech(in samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var detector = EnergyVoiceActivityDetector(configuration: configuration, sampleRate: 16_000)
        return samples.withUnsafeBufferPointer { detector.ingest($0).speechStart != nil }
    }
}

struct LongFormMetrics: Sendable, Equatable {
    var inferenceSeconds: Double = 0
    var transcribedAudioSeconds: Double = 0
    var maximumQueueDelay: Double = 0
    var peakQueuedWindows: Int = 0
    var skippedSilentWindows: Int = 0
    var skippedSilentAudioSeconds: Double = 0
    var lostIntervals: Int = 0

    var realTimeFactor: Double? {
        transcribedAudioSeconds > 0 ? inferenceSeconds / transcribedAudioSeconds : nil
    }
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
    private let speechClassifier: @Sendable (MeetingRecognitionAudio) -> Bool
    private let uptime: @Sendable () -> TimeInterval
    private var queues: [MeetingAudioSource: [QueuedMeetingWindow]] = [.microphone: [], .system: []]
    private var lastSource: MeetingAudioSource = .system
    private var processing = false
    private var cancelled = false
    private var generation: UInt64 = 0
    private(set) var assembler = MeetingTranscriptAssembler()
    private(set) var metrics = LongFormMetrics()

    init(engine: any TranscriptionService, profile: LanguageProfile, capacity: Int = 8,
         speechClassifier: @escaping @Sendable (MeetingRecognitionAudio) -> Bool = {
             MeetingSpeechDetector().containsSpeech(in: $0.samples)
         },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(capacity > 0)
        self.engine = engine
        self.profile = profile
        self.capacity = capacity
        self.speechClassifier = speechClassifier
        self.uptime = uptime
    }

    func enqueue(_ window: MeetingRecognitionAudio) throws {
        guard !cancelled else { throw LongFormTranscriptionError.cancelled }
        guard queues.values.reduce(0, { $0 + $1.count }) < capacity else { throw LongFormTranscriptionError.backlogFull }
        queues[window.source, default: []].append(QueuedMeetingWindow(audio: window, enqueuedAt: uptime()))
        metrics.peakQueuedWindows = max(metrics.peakQueuedWindows, queues.values.reduce(0) { $0 + $1.count })
    }

    func drainOne() async throws -> Bool {
        guard !cancelled, !Task.isCancelled else { throw LongFormTranscriptionError.cancelled }
        guard !processing else { throw LongFormTranscriptionError.alreadyProcessing }
        let preferred: MeetingAudioSource = lastSource == .system ? .microphone : .system
        let alternate: MeetingAudioSource = preferred == .system ? .microphone : .system
        let source = !(queues[preferred] ?? []).isEmpty ? preferred : alternate
        guard let queued = queues[source]?.first else { return false }
        let window = queued.audio
        if !speechClassifier(window) {
            queues[source]?.removeFirst()
            lastSource = source
            metrics.skippedSilentWindows += 1
            metrics.skippedSilentAudioSeconds += Double(window.samples.count) / 16_000
            return true
        }
        processing = true
        defer { processing = false }
        guard await engine.modelState(for: profile).isReady else { throw LongFormTranscriptionError.modelNotReady }
        let utterance = CapturedUtterance(samples: window.samples, sampleRate: 16_000, peakLevel: 0,
                                          droppedFrameCount: 0, voiceActivity: .initial, endReason: .hotkeyRelease)
        let started = uptime()
        metrics.maximumQueueDelay = max(metrics.maximumQueueDelay, started - queued.enqueuedAt)
        let operationGeneration = generation
        let transcript: Transcript
        do {
            transcript = try await engine.transcribe(utterance, profile: profile)
        } catch {
            if Task.isCancelled || error as? TranscriptionError == .cancelled {
                throw LongFormTranscriptionError.cancelled
            }
            throw error
        }
        guard !cancelled, generation == operationGeneration else { throw LongFormTranscriptionError.cancelled }
        metrics.inferenceSeconds += uptime() - started
        metrics.transcribedAudioSeconds += Double(window.samples.count) / 16_000
        queues[source]?.removeFirst()
        lastSource = source
        assembler.append(MeetingTranscriptWindow(source: source, startFrame: window.startFrame,
                                                endFrame: window.endFrame, transcript: transcript))
        return true
    }

    func queuedCount() -> Int { queues.values.reduce(0) { $0 + $1.count } }

    func recordLostIntervals(_ count: Int = 1) {
        metrics.lostIntervals += max(count, 0)
    }

    /// Invalidates an in-flight result and releases every queued audio window.
    /// The assembled rows remain available as an explicit partial transcript.
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        metrics.lostIntervals += queuedCount()
        queues = [.microphone: [], .system: []]
    }
}
