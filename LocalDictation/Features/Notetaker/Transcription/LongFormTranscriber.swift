import Foundation

struct MeetingRecognitionAudio: Sendable {
    let source: MeetingAudioSource
    let startFrame: Int64
    let samples: [Float]
    var endFrame: Int64 { startFrame + Int64(samples.count) }
}

enum LongFormTranscriptionError: Error, Equatable {
    case invalidFormat
    case backlogFull
    case alreadyProcessing
    case modelNotReady
    case cancelled
}

/// One source is windowed independently. A process tap can be sparse while its
/// app is silent and macOS may delay microphone delivery during system UI such
/// as screenshots. A forward gap closes the current window and starts another
/// at the real host-time position. No silence is invented.
///
/// Windows do not overlap. Each one ends in a pause: after `minimumFrames` the
/// builder waits for `pauseFrames` that are quiet relative to the window's own
/// speech and cuts in the middle of them. Without such a pause it cuts at the
/// quietest stretch once `maximumFrames` is reached. Overlapping fixed windows
/// recognised the same words twice with different spellings, which no
/// boundary repair could reconcile: on 23.10 16-22% of the words repeated.
struct MeetingWindowBuilder {
    let source: MeetingAudioSource
    let minimumFrames: Int
    let maximumFrames: Int
    let pauseFrames: Int
    private var startFrame: Int64?
    private var samples: [Float] = []
    /// Mean square of every complete `energyFrame` in `samples`.
    private var energies: [Float] = []

    static let energyFrame = 320
    /// A pause is at least this much quieter than the window's loud speech.
    static let pauseRatio: Float = 0.01
    /// Below this mean square a frame is a pause whatever the speech level.
    static let silenceFloor: Float = 0.000_004

    /// The first result arrives after about eight seconds, as before; every
    /// window stays well inside the model's thirty-second context.
    init(source: MeetingAudioSource) {
        self.init(source: source, minimumFrames: 128_000, maximumFrames: 320_000, pauseFrames: 4_800)
    }

    /// Explicit sizes keep deterministic tests and probes independent of the
    /// production live-window policy. Sizes are whole energy frames.
    init(source: MeetingAudioSource, minimumFrames: Int, maximumFrames: Int, pauseFrames: Int) {
        precondition(minimumFrames > 0 && minimumFrames <= maximumFrames
                     && pauseFrames >= Self.energyFrame && pauseFrames < minimumFrames
                     && [minimumFrames, maximumFrames, pauseFrames].allSatisfy { $0 % Self.energyFrame == 0 })
        self.source = source
        self.minimumFrames = minimumFrames
        self.maximumFrames = maximumFrames
        self.pauseFrames = pauseFrames
    }

    mutating func append(_ chunk: MeetingAudioChunk) throws -> [MeetingRecognitionAudio] {
        guard chunk.source == source, chunk.sampleRate == 16_000, chunk.samples.count <= maximumFrames else { throw LongFormTranscriptionError.invalidFormat }
        var result: [MeetingRecognitionAudio] = []
        var incoming = chunk.samples[...]
        var incomingStart = chunk.startFrame
        if let startFrame {
            let expected = startFrame + Int64(samples.count)
            let delta = incomingStart - expected
            if delta > 2 {
                if let window = flush() { result.append(window) }
                self.startFrame = incomingStart
            } else if delta < -2 {
                // The timeline already resynchronises a fast device clock;
                // anything still overlapping here was heard once already.
                incoming = incoming.dropFirst(Int(min(-delta, Int64(incoming.count))))
                incomingStart = expected
            }
        } else {
            startFrame = incomingStart
        }
        guard !incoming.isEmpty else { return result }
        appendSamples(incoming)
        while let cut = cutFrame() {
            result.append(emit(frames: cut))
        }
        return result
    }

    mutating func finish() -> MeetingRecognitionAudio? {
        flush()
    }

    private mutating func appendSamples(_ values: ArraySlice<Float>) {
        let completeBefore = samples.count / Self.energyFrame
        samples.append(contentsOf: values)
        let completeAfter = samples.count / Self.energyFrame
        guard completeAfter > completeBefore else { return }
        samples.withUnsafeBufferPointer { buffer in
            for frame in completeBefore..<completeAfter {
                var sum: Float = 0
                for value in buffer[(frame * Self.energyFrame)..<((frame + 1) * Self.energyFrame)] {
                    sum += value * value
                }
                energies.append(sum / Float(Self.energyFrame))
            }
        }
    }

    /// The frame index to cut at, or nil while the window should keep growing.
    private func cutFrame() -> Int? {
        guard samples.count >= minimumFrames else { return nil }
        let run = pauseFrames / Self.energyFrame
        let minimumEnergyFrames = minimumFrames / Self.energyFrame
        let maximumEnergyFrames = maximumFrames / Self.energyFrame
        let searchEnd = min(energies.count, maximumEnergyFrames)
        // A pause may begin slightly before the minimum as long as it ends after it.
        let firstRunStart = max(minimumEnergyFrames - run, 0)
        guard searchEnd - firstRunStart >= run else { return nil }

        let sorted = energies[..<searchEnd].sorted()
        let loud = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        let threshold = max(Self.silenceFloor, loud * Self.pauseRatio)
        var quietRun = 0
        for index in 0..<searchEnd {
            quietRun = energies[index] <= threshold ? quietRun + 1 : 0
            let runStart = index - run + 1
            if quietRun >= run, runStart >= firstRunStart {
                return (runStart + run / 2) * Self.energyFrame
            }
        }
        guard samples.count >= maximumFrames else { return nil }

        // Without a pause the window still never ends before the minimum.
        let fallbackStart = minimumEnergyFrames
        guard searchEnd - fallbackStart >= run else { return maximumFrames }
        var best = fallbackStart
        var bestEnergy = Float.greatestFiniteMagnitude
        var windowEnergy = energies[fallbackStart..<(fallbackStart + run)].reduce(0, +)
        for runStart in fallbackStart...(searchEnd - run) {
            if runStart > fallbackStart {
                windowEnergy += energies[runStart + run - 1] - energies[runStart - 1]
            }
            if windowEnergy < bestEnergy {
                bestEnergy = windowEnergy
                best = runStart
            }
        }
        return (best + run / 2) * Self.energyFrame
    }

    private mutating func emit(frames: Int) -> MeetingRecognitionAudio {
        let start = startFrame ?? 0
        let window = MeetingRecognitionAudio(source: source, startFrame: start, samples: Array(samples.prefix(frames)))
        samples.removeFirst(frames)
        energies.removeFirst(frames / Self.energyFrame)
        startFrame = start + Int64(frames)
        return window
    }

    private mutating func flush() -> MeetingRecognitionAudio? {
        let result: MeetingRecognitionAudio?
        if let startFrame, !samples.isEmpty {
            result = MeetingRecognitionAudio(source: source, startFrame: startFrame, samples: samples)
        } else {
            result = nil
        }
        samples = []
        energies = []
        startFrame = nil
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
