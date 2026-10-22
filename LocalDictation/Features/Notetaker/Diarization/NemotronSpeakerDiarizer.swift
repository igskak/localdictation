import Foundation

#if NOTETAKER_DIARIZATION
@preconcurrency import WitnessDiarizationRuntime
import CoreML
#endif

enum DiarizationDisplayState: Sendable, Equatable {
    case unavailable
    case preparing
    case active
    case fallback
    case failed
}

struct DiarizationRuntimeMetrics: Sendable, Equatable {
    var modelLoadSeconds: Double = 0
    var inferenceSeconds: Double = 0
    var processedAudioSeconds: Double = 0
    var emittedTurns: Int = 0
    var discontinuities: Int = 0

    var realTimeFactor: Double? {
        processedAudioSeconds > 0 ? inferenceSeconds / processedAudioSeconds : nil
    }
}

enum ProductionDiarizationError: Error, Sendable, Equatable {
    case unavailableInBuild
    case bundledModelMissing
    case notPrepared
    case invalidAudioFormat
}

protocol StreamingSpeakerDiarizationService: Sendable {
    func prepare() async throws
    func ingest(_ chunk: MeetingAudioChunk) async throws -> [DiarizedSpeakerTurn]
    func finish() async throws -> [DiarizedSpeakerTurn]
    func metricsSnapshot() async -> DiarizationRuntimeMetrics
}

actor UnavailableStreamingSpeakerDiarizer: StreamingSpeakerDiarizationService {
    func prepare() throws { throw ProductionDiarizationError.unavailableInBuild }
    func ingest(_ chunk: MeetingAudioChunk) -> [DiarizedSpeakerTurn] { [] }
    func finish() -> [DiarizedSpeakerTurn] { [] }
    func metricsSnapshot() -> DiarizationRuntimeMetrics { DiarizationRuntimeMetrics() }
}

/// Converts flattened 10 ms speaker probabilities into overlapping turns. It
/// intentionally keeps arrival-ordered anonymous slot IDs and confidence.
struct NemotronProbabilitySegmenter: Sendable {
    let threshold: Float
    let minimumFrames: Int
    let samplesPerProbabilityFrame: Int64

    init(threshold: Float = 0.5, minimumFrames: Int = 3, sampleRate: Int = 16_000) {
        precondition((0...1).contains(threshold) && minimumFrames > 0 && sampleRate > 0)
        self.threshold = threshold
        self.minimumFrames = minimumFrames
        samplesPerProbabilityFrame = Int64(sampleRate / 100)
    }

    func turns(
        probabilities: [Float],
        frameCount: Int,
        speakerCount: Int,
        startFrame: Int64
    ) -> [DiarizedSpeakerTurn] {
        guard frameCount > 0, speakerCount > 0,
              probabilities.count >= frameCount * speakerCount else { return [] }
        var turns: [DiarizedSpeakerTurn] = []
        for speaker in 0..<speakerCount {
            var activeStart: Int?
            var probabilitySum: Double = 0
            for frame in 0...frameCount {
                let probability = frame < frameCount
                    ? probabilities[frame * speakerCount + speaker]
                    : 0
                if probability >= threshold {
                    if activeStart == nil { activeStart = frame }
                    probabilitySum += Double(probability)
                } else if let start = activeStart {
                    let duration = frame - start
                    if duration >= minimumFrames {
                        turns.append(DiarizedSpeakerTurn(
                            speakerID: "speaker-\(speaker + 1)",
                            startFrame: startFrame + Int64(start) * samplesPerProbabilityFrame,
                            endFrame: startFrame + Int64(frame) * samplesPerProbabilityFrame,
                            confidence: min(max(probabilitySum / Double(duration), 0), 1)
                        ))
                    }
                    activeStart = nil
                    probabilitySum = 0
                }
            }
        }
        return turns.sorted {
            if $0.startFrame != $1.startFrame { return $0.startFrame < $1.startFrame }
            return $0.speakerID < $1.speakerID
        }
    }
}

enum ProductionDiarizationFactory {
    #if NOTETAKER_DIARIZATION
    private static let shared = BundledNemotronSpeakerDiarizer()
    #endif

    static func make() -> any StreamingSpeakerDiarizationService {
        #if NOTETAKER_DIARIZATION
        shared
        #else
        UnavailableStreamingSpeakerDiarizer()
        #endif
    }

    static func warmUpIfAvailable() async {
        #if NOTETAKER_DIARIZATION
        try? await shared.prepare()
        #endif
    }
}

#if NOTETAKER_DIARIZATION
/// Actor-isolated because FluidAudio's streaming model carries mutable speaker
/// cache and is intentionally not thread-safe. The model is loaded only from
/// the signed app bundle; this adapter never performs a network request.
actor BundledNemotronSpeakerDiarizer: StreamingSpeakerDiarizationService {
    private enum PreparationState {
        case idle
        case loading
        case ready
    }

    static let profileName = "c128-split-w8a8"
    static let resourceDirectoryName = "Nemotron3"

    private let modelDirectory: URL?
    private let segmenter: NemotronProbabilitySegmenter
    private var preparationState: PreparationState = .idle
    private var preparationWaiters: [CheckedContinuation<Void, any Error>] = []
    private var model: WitnessNemotron3Diarizer?
    private var streamOriginFrame: Int64?
    private var expectedInputFrame: Int64?
    private var emittedProbabilityFrames = 0
    private var metrics = DiarizationRuntimeMetrics()

    init(
        modelDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent(BundledNemotronSpeakerDiarizer.resourceDirectoryName),
        segmenter: NemotronProbabilitySegmenter = NemotronProbabilitySegmenter()
    ) {
        self.modelDirectory = modelDirectory
        self.segmenter = segmenter
    }

    func prepare() async throws {
        switch preparationState {
        case .ready:
            return
        case .loading:
            try await withCheckedThrowingContinuation { continuation in
                preparationWaiters.append(continuation)
            }
            return
        case .idle:
            preparationState = .loading
        }
        guard let modelDirectory,
              FileManager.default.fileExists(atPath: modelDirectory.path),
              let config = WitnessNemotron3Config.preset(named: Self.profileName) else {
            preparationState = .idle
            throw ProductionDiarizationError.bundledModelMissing
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let models = try await WitnessNemotron3Models.load(
                config: config,
                directory: modelDirectory,
                computeUnits: .all
            )
            model = WitnessNemotron3Diarizer(config: config, models: models)
            metrics.modelLoadSeconds = ProcessInfo.processInfo.systemUptime - started
            preparationState = .ready
            let waiters = preparationWaiters
            preparationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        } catch {
            preparationState = .idle
            let waiters = preparationWaiters
            preparationWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    func ingest(_ chunk: MeetingAudioChunk) throws -> [DiarizedSpeakerTurn] {
        guard chunk.source == .system,
              abs(chunk.sampleRate - AudioTargetFormat.sampleRate) < 0.1 else {
            throw ProductionDiarizationError.invalidAudioFormat
        }
        guard let model else { throw ProductionDiarizationError.notPrepared }
        do {
            var turns: [DiarizedSpeakerTurn] = []
            if let expectedInputFrame, abs(chunk.startFrame - expectedInputFrame) > 2 {
                turns.append(contentsOf: try finishCurrentStream(using: model))
                metrics.discontinuities += 1
            }
            if streamOriginFrame == nil { streamOriginFrame = chunk.startFrame }
            let started = ProcessInfo.processInfo.systemUptime
            model.appendAudio(chunk.samples)
            let results = try model.processBufferedAudio()
            metrics.inferenceSeconds += ProcessInfo.processInfo.systemUptime - started
            metrics.processedAudioSeconds += Double(chunk.samples.count) / AudioTargetFormat.sampleRate
            expectedInputFrame = chunk.startFrame + Int64(chunk.samples.count)
            turns.append(contentsOf: convert(results))
            metrics.emittedTurns += turns.count
            return turns
        } catch {
            resetStream(using: model)
            throw error
        }
    }

    func finish() throws -> [DiarizedSpeakerTurn] {
        guard let model else { return [] }
        do {
            let turns = try finishCurrentStream(using: model)
            metrics.emittedTurns += turns.count
            return turns
        } catch {
            resetStream(using: model)
            throw error
        }
    }

    func metricsSnapshot() -> DiarizationRuntimeMetrics { metrics }

    private func finishCurrentStream(using model: WitnessNemotron3Diarizer) throws -> [DiarizedSpeakerTurn] {
        let started = ProcessInfo.processInfo.systemUptime
        let results = try model.finishStream()
        metrics.inferenceSeconds += ProcessInfo.processInfo.systemUptime - started
        let turns = convert(results)
        resetStream(using: model)
        return turns
    }

    private func resetStream(using model: WitnessNemotron3Diarizer) {
        model.reset()
        streamOriginFrame = nil
        expectedInputFrame = nil
        emittedProbabilityFrames = 0
    }

    private func convert(_ results: [WitnessNemotron3ChunkResult]) -> [DiarizedSpeakerTurn] {
        guard let origin = streamOriginFrame else { return [] }
        var turns: [DiarizedSpeakerTurn] = []
        for result in results {
            let start = origin + Int64(emittedProbabilityFrames) * segmenter.samplesPerProbabilityFrame
            turns.append(contentsOf: segmenter.turns(
                probabilities: result.probabilities,
                frameCount: result.frameCount,
                speakerCount: result.numSpeakers,
                startFrame: start
            ))
            emittedProbabilityFrames += result.frameCount
        }
        return turns
    }
}
#endif
