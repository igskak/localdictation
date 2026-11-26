import Foundation

#if NOTETAKER_DIARIZATION
@preconcurrency import WitnessDiarizationRuntime
import CoreML
#endif

enum DiarizationDisplayState: Sendable, Equatable {
    case unavailable
    case preparing
    case active
    case reviewing
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

/// What each speaker slot did over a stretch of the stream, for the log only.
/// `NemotronProbabilitySegmenter` keeps a slot only at 0.5 or above, so a
/// second voice that sits at 0.4 produces no turn and no trace. Counting frames
/// at lower levels shows whether the slots are quiet or merely under the line.
/// Frames are the model's 10 ms probability frames.
struct SpeakerSlotProbabilityDigest: Sendable, Equatable {
    struct Slot: Sendable, Equatable {
        var peak: Float = 0
        var sum: Double = 0
        var framesAtOrAbove50 = 0
        var framesAtOrAbove30 = 0
        var framesAtOrAbove20 = 0
        /// Frames where this slot had the highest probability of all slots
        /// and that probability was at least 0.2.
        var framesLeading = 0
    }

    static let probabilityFramesPerSecond = 100

    private(set) var slots: [Slot] = []
    private(set) var frames = 0
    private(set) var startFrame: Int64?
    private(set) var endFrame: Int64 = 0

    var isEmpty: Bool { frames == 0 }

    mutating func add(probabilities: [Float], frameCount: Int, speakerCount: Int,
                      startFrame: Int64, samplesPerProbabilityFrame: Int64) {
        guard frameCount > 0, speakerCount > 0,
              probabilities.count >= frameCount * speakerCount else { return }
        if slots.count < speakerCount {
            slots.append(contentsOf: Array(repeating: Slot(), count: speakerCount - slots.count))
        }
        if self.startFrame == nil { self.startFrame = startFrame }
        endFrame = startFrame + Int64(frameCount) * samplesPerProbabilityFrame
        for frame in 0..<frameCount {
            var leader = 0
            var leaderProbability: Float = -1
            for speaker in 0..<speakerCount {
                let probability = probabilities[frame * speakerCount + speaker]
                slots[speaker].peak = max(slots[speaker].peak, probability)
                slots[speaker].sum += Double(probability)
                if probability >= 0.5 { slots[speaker].framesAtOrAbove50 += 1 }
                if probability >= 0.3 { slots[speaker].framesAtOrAbove30 += 1 }
                if probability >= 0.2 { slots[speaker].framesAtOrAbove20 += 1 }
                if probability > leaderProbability {
                    leader = speaker
                    leaderProbability = probability
                }
            }
            if leaderProbability >= 0.2 { slots[leader].framesLeading += 1 }
        }
        frames += frameCount
    }

    mutating func reset() {
        self = SpeakerSlotProbabilityDigest()
    }

    /// Positions are seconds on the 16 kHz host-time grid used by the
    /// transcript rows. Counts are 10 ms frames; "lead" is the number of frames
    /// where the slot was highest and at least 0.2.
    func summary(sampleRate: Double = 16_000) -> String {
        guard let startFrame, frames > 0 else { return "no frames" }
        func seconds(_ frame: Int64) -> String { String(format: "%.1f", Double(frame) / sampleRate) }
        let perSlot = slots.enumerated().map { index, slot in
            String(format: "slot %d peak %.2f mean %.3f >=0.5:%d >=0.3:%d >=0.2:%d lead:%d",
                   index + 1, slot.peak, slot.sum / Double(frames),
                   slot.framesAtOrAbove50, slot.framesAtOrAbove30, slot.framesAtOrAbove20, slot.framesLeading)
        }
        return "\(seconds(startFrame))-\(seconds(endFrame)) s, \(frames) frames: " + perSlot.joined(separator: "; ")
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

    static func makeReview() -> (any MeetingSpeakerReviewing)? {
        #if NOTETAKER_DIARIZATION
        if #available(macOS 15, *) { return BundledCommunitySpeakerReview() }
        #endif
        return nil
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
    private var slotDigest = SpeakerSlotProbabilityDigest()
    /// One log line per ten seconds of stream.
    private static let digestFrames = 10 * SpeakerSlotProbabilityDigest.probabilityFramesPerSecond

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
        logSlotDigest()
        resetStream(using: model)
        return turns
    }

    private func logSlotDigest() {
        guard !slotDigest.isEmpty else { return }
        let summary = slotDigest.summary()
        Log.audio.notice("Diarization slots \(summary, privacy: .public)")
        slotDigest.reset()
    }

    private func resetStream(using model: WitnessNemotron3Diarizer) {
        model.reset()
        slotDigest.reset()
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
            slotDigest.add(
                probabilities: result.probabilities,
                frameCount: result.frameCount,
                speakerCount: result.numSpeakers,
                startFrame: start,
                samplesPerProbabilityFrame: segmenter.samplesPerProbabilityFrame
            )
            if slotDigest.frames >= Self.digestFrames { logSlotDigest() }
            emittedProbabilityFrames += result.frameCount
        }
        return turns
    }
}
/// The review model is loaded directly from verified, compiled app resources.
/// FluidAudio's model discovery and its download fallback are never invoked.
actor BundledCommunitySpeakerReview: MeetingSpeakerReviewing {
    private let directory: URL?
    private var models: WitnessOfflineDiarizerModels?

    init(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("CommunitySpeakerReview")) {
        self.directory = directory
    }

    func prepare() async throws {
        guard #available(macOS 15, *) else { throw ProductionDiarizationError.unavailableInBuild }
        guard models == nil else { return }
        guard let directory else { throw ProductionDiarizationError.bundledModelMissing }
        let start = ProcessInfo.processInfo.systemUptime
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly

        struct Parameters: Decodable {
            struct Tensor: Decodable { let data_base64: String }
            let tensors: [String: Tensor]
        }
        let parameterURL = directory.appendingPathComponent("plda-parameters.json")
        let parameters = try JSONDecoder().decode(Parameters.self, from: Data(contentsOf: parameterURL))
        guard let encoded = parameters.tensors["psi"]?.data_base64,
              let data = Data(base64Encoded: encoded), data.count == 128 * MemoryLayout<Float>.size else {
            throw ProductionDiarizationError.bundledModelMissing
        }
        let psi = data.withUnsafeBytes { bytes in
            (0..<128).map {
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))))
            }
        }
        let segmentation = try await MLModel.load(contentsOf: directory.appendingPathComponent("Segmentation.mlmodelc"), configuration: config)
        let fbank = try await MLModel.load(contentsOf: directory.appendingPathComponent("FBank.mlmodelc"), configuration: cpu)
        let embedding = try await MLModel.load(contentsOf: directory.appendingPathComponent("Embedding.mlmodelc"), configuration: config)
        let plda = try await MLModel.load(contentsOf: directory.appendingPathComponent("PldaRho.mlmodelc"), configuration: config)
        models = WitnessOfflineDiarizerModels(
            segmentationModel: segmentation, fbankModel: fbank, embeddingModel: embedding,
            pldaRhoModel: plda, pldaPsi: psi,
            compilationDuration: ProcessInfo.processInfo.systemUptime - start
        )
    }

    func review(_ audio: MeetingRecognitionAudio) async throws -> MeetingSpeakerReview {
        guard let models else { throw ProductionDiarizationError.notPrepared }
        return try await Self.run(models: models, audio: audio)
    }

    private static func run(models: WitnessOfflineDiarizerModels, audio: MeetingRecognitionAudio) async throws -> MeetingSpeakerReview {
        var config = WitnessOfflineDiarizerConfig()
        config.postProcessing.exclusiveSegments = false
        let manager = WitnessOfflineDiarizer(config: config)
        manager.initialize(models: models)
        let result: WitnessOfflineDiarizerResult
        do {
            result = try await manager.process(audio: audio.samples)
        } catch WitnessOfflineDiarizationError.noSpeechDetected {
            return MeetingSpeakerReview(turns: [], embeddings: [:])
        }
        let scale = AudioTargetFormat.sampleRate
        let range = audio.startFrame..<audio.endFrame
        let turns = result.segments.compactMap { segment in
            DiarizedSpeakerTurn(
                speakerID: segment.speakerId,
                startFrame: audio.startFrame + Int64((Double(segment.startTimeSeconds) * scale).rounded()),
                endFrame: audio.startFrame + Int64((Double(segment.endTimeSeconds) * scale).rounded()),
                confidence: Double(segment.qualityScore)
            ).clipped(to: range)
        }
        return MeetingSpeakerReview(turns: turns, embeddings: result.speakerDatabase ?? [:])
    }
}
#endif
