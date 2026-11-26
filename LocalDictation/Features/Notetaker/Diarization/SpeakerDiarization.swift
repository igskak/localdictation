import Foundation

enum SpeakerAssignmentSource: String, Codable, Sendable, Equatable {
    case sourceFallback
    case diarization
    case manual
}

struct SpeakerWordAttribution: Codable, Sendable, Equatable {
    let text: String
    let startFrame: Int64
    let endFrame: Int64
    let speakerID: String
    let confidence: Double
}

struct DiarizedSpeakerTurn: Sendable, Equatable {
    let speakerID: String
    let startFrame: Int64
    let endFrame: Int64
    let confidence: Double
}

extension DiarizedSpeakerTurn {
    func clipped(to range: Range<Int64>) -> Self? {
        let start = max(startFrame, range.lowerBound)
        let end = min(endFrame, range.upperBound)
        guard end > start else { return nil }
        return Self(speakerID: speakerID, startFrame: start, endFrame: end, confidence: confidence)
    }

    func subtracting(_ range: Range<Int64>) -> [Self] {
        guard range.overlaps(startFrame..<endFrame) else { return [self] }
        return [
            clipped(to: Int64.min..<range.lowerBound),
            clipped(to: range.upperBound..<Int64.max)
        ].compactMap { $0 }
    }
}

struct SpeakerTimelineUpdate: Sendable {
    let turns: [DiarizedSpeakerTurn]
    var replacing: Range<Int64>?

    var affectedFrames: Range<Int64>? {
        if let replacing { return replacing.isEmpty ? nil : replacing }
        guard let start = turns.map(\.startFrame).min(),
              let end = turns.map(\.endFrame).max(), end > start else { return nil }
        return start..<end
    }
}

struct MeetingSpeakerReview: Sendable {
    let turns: [DiarizedSpeakerTurn]
    let embeddings: [String: [Float]]
}

protocol MeetingSpeakerReviewing: Sendable {
    func prepare() async throws
    func review(_ audio: MeetingRecognitionAudio) async throws -> MeetingSpeakerReview
}

/// Rolling system audio is retained only for the current on-device review.
struct MeetingSpeakerReviewBuffer: Sendable {
    private static let rate = Int(AudioTargetFormat.sampleRate)
    private let capacity = 32 * rate
    private let minimumFrames = 12 * rate
    private let step = Int64(10 * rate)
    private var samples: [Float] = []
    private var startFrame: Int64 = 0
    private var lastScheduledEnd: Int64?

    mutating func append(_ chunk: MeetingAudioChunk) {
        guard chunk.source == .system, chunk.sampleRate == AudioTargetFormat.sampleRate,
              !chunk.samples.isEmpty else { return }
        let endFrame = startFrame + Int64(samples.count)
        let gap = chunk.startFrame - endFrame
        if samples.isEmpty || gap < 0 || gap > Int64(capacity / 2) {
            samples.removeAll(keepingCapacity: true)
            startFrame = chunk.startFrame
            lastScheduledEnd = nil
        } else if gap > 0 {
            samples.append(contentsOf: repeatElement(0, count: Int(gap)))
        }
        samples.append(contentsOf: chunk.samples)
        // Trim in blocks to avoid moving the buffer on each audio callback.
        if samples.count > capacity + 2 * Self.rate {
            let excess = samples.count - capacity
            samples.removeFirst(excess)
            startFrame += Int64(excess)
        }
    }

    mutating func takeWindow(final: Bool = false) -> MeetingRecognitionAudio? {
        guard samples.count >= (final ? 2 * Self.rate : minimumFrames) else { return nil }
        let end = startFrame + Int64(samples.count)
        if let lastScheduledEnd, end - lastScheduledEnd < (final ? 1 : step) { return nil }
        lastScheduledEnd = end
        let count = min(samples.count, capacity)
        return MeetingRecognitionAudio(
            source: .system, startFrame: end - Int64(count), samples: Array(samples.suffix(count))
        )
    }
}

/// Each review starts clustering from scratch. Match the new clusters to
/// session-local IDs with overlapping audio and fixed speaker embeddings.
struct MeetingSpeakerIdentityTracker: Sendable {
    private struct Cluster {
        let turns: [DiarizedSpeakerTurn]
        let voice: [Float]
        var firstFrame: Int64 { turns[0].startFrame }
        var supportedFrames: Int64 { turns.reduce(0) { $0 + $1.endFrame - $1.startFrame } }
    }

    private var voices: [[Float]] = []
    private var recent: [DiarizedSpeakerTurn] = []
    private var lastWindow: Range<Int64>?

    mutating func update(_ review: MeetingSpeakerReview, window: MeetingRecognitionAudio) -> SpeakerTimelineUpdate? {
        let usable = review.turns.filter { $0.confidence >= 0.55 }
        let clusters = Dictionary(grouping: usable, by: \.speakerID).compactMap { key, turns -> Cluster? in
            guard let voice = review.embeddings[key].flatMap(Self.normalized) else { return nil }
            return Cluster(turns: turns.sorted { $0.startFrame < $1.startFrame }, voice: voice)
        }.sorted {
            $0.firstFrame == $1.firstFrame ? $0.turns[0].speakerID < $1.turns[0].speakerID : $0.firstFrame < $1.firstFrame
        }

        // Clusters in one pass represent distinct voices. Match only to
        // session IDs that were already present before this pass.
        let known = voices
        var used: Set<Int> = []
        var turns: [DiarizedSpeakerTurn] = []
        for cluster in clusters {
            let similar = known.enumerated().map { index, voice in
                (index: index, score: Self.similarity(cluster.voice, voice))
            }.sorted { $0.score > $1.score }
            let support = known.indices.map { index in
                let id = "speaker-\(index + 1)"
                let frames = cluster.turns.reduce(Int64(0)) { total, turn in
                    total + recent.reduce(Int64(0)) { overlap, earlier in
                        guard earlier.speakerID == id else { return overlap }
                        return overlap + max(0, min(turn.endFrame, earlier.endFrame) - max(turn.startFrame, earlier.startFrame))
                    }
                }
                return (index: index, frames: frames)
            }.sorted { $0.frames > $1.frames }

            let identity: Int
            if let match = support.first, match.frames >= 16_000,
               match.frames >= (support.dropFirst().first?.frames ?? 0) + 8_000,
               Self.similarity(cluster.voice, known[match.index]) >= 0.40 {
                identity = match.index
            } else if let match = similar.first, match.score >= 0.70,
                      match.score - (similar.dropFirst().first?.score ?? 0) >= 0.12 {
                identity = match.index
            } else if (similar.first?.score ?? 0) < 0.45,
                      cluster.supportedFrames >= 24_000, voices.count < 8 {
                identity = voices.count
                voices.append(cluster.voice)
            } else {
                continue
            }
            guard used.insert(identity).inserted else { continue }
            let speaker = "speaker-\(identity + 1)"
            turns += cluster.turns.map {
                DiarizedSpeakerTurn(speakerID: speaker, startFrame: $0.startFrame,
                                    endFrame: $0.endFrame, confidence: $0.confidence)
            }
        }

        guard !turns.isEmpty else { return nil }
        // Far-left edge predictions in a repeated window lack the context
        // that was available in the previous pass.
        let start: Int64
        if let lastWindow, window.startFrame > lastWindow.lowerBound, window.startFrame < lastWindow.upperBound {
            start = min(window.startFrame + 32_000, lastWindow.upperBound, window.endFrame)
        } else {
            start = window.startFrame
        }
        let replacement = start..<window.endFrame
        let revised = turns.compactMap { $0.clipped(to: replacement) }
        guard !revised.isEmpty else { return nil }
        lastWindow = window.startFrame..<window.endFrame
        recent = (recent.flatMap { $0.subtracting(replacement) } + revised)
            .compactMap { $0.clipped(to: window.startFrame..<window.endFrame) }
        return SpeakerTimelineUpdate(turns: revised, replacing: replacement)
    }

    private static func normalized(_ voice: [Float]) -> [Float]? {
        let norm = sqrt(voice.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return voice.map { $0 / norm }
    }

    private static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return 0 }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

struct SpeakerAlignment: Sendable, Equatable {
    let speakerID: String
    let confidence: Double
    let words: [SpeakerWordAttribution]
}

/// Converts local diarizer turns into transcript attribution. A confidence is
/// retained for both the whole segment and each timed word; callers decide
/// whether the measured release gate permits showing the hypothesis.
struct SpeakerAttributionAligner: Sendable {
    func align(
        row: MeetingTranscriptRow,
        turns: [DiarizedSpeakerTurn],
        sampleRate: Double = AudioTargetFormat.sampleRate
    ) -> SpeakerAlignment? {
        guard row.source == .system, row.endFrame > row.startFrame, sampleRate > 0 else { return nil }
        let segment = attribution(start: row.startFrame, end: row.endFrame, turns: turns)
        guard let segment else { return nil }

        let words = row.original.tokens.map { token in
            wordAttribution(for: token, rowStart: row.startFrame, turns: turns, sampleRate: sampleRate)
        }.filter { $0.speakerID != "others" }
        return SpeakerAlignment(speakerID: segment.speakerID, confidence: segment.confidence, words: words)
    }

    func wordAttribution(
        for token: TranscriptToken,
        rowStart: Int64,
        turns: [DiarizedSpeakerTurn],
        sampleRate: Double
    ) -> SpeakerWordAttribution {
        let start = rowStart + Int64((max(token.start, 0) * sampleRate).rounded())
        let end = max(start + 1, rowStart + Int64((max(token.end, token.start) * sampleRate).rounded()))
        // Similar support from another slot makes this word ambiguous.
        let value = attribution(start: start, end: end, turns: turns, minimumLead: 0.15)
        return SpeakerWordAttribution(
            text: token.text,
            startFrame: start,
            endFrame: end,
            speakerID: value?.speakerID ?? "others",
            confidence: value?.confidence ?? 0
        )
    }

    private func attribution(
        start: Int64,
        end: Int64,
        turns: [DiarizedSpeakerTurn],
        minimumLead: Double = 0
    ) -> (speakerID: String, confidence: Double)? {
        guard end > start else { return nil }
        var durationBySpeaker: [String: Double] = [:]
        var weightedConfidenceBySpeaker: [String: Double] = [:]
        for turn in turns where turn.endFrame > start && turn.startFrame < end {
            let overlap = Double(max(min(end, turn.endFrame) - max(start, turn.startFrame), 0))
            guard overlap > 0 else { continue }
            durationBySpeaker[turn.speakerID, default: 0] += overlap
            weightedConfidenceBySpeaker[turn.speakerID, default: 0] += overlap * min(max(turn.confidence, 0), 1)
        }
        let support = minimumLead > 0 ? weightedConfidenceBySpeaker : durationBySpeaker
        guard let winner = support.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) else { return nil }
        let intervalDuration = Double(end - start)
        let confidence = weightedConfidenceBySpeaker[winner.key, default: 0] / intervalDuration
        if minimumLead > 0 {
            let runnerUp = weightedConfidenceBySpeaker.lazy.filter { $0.key != winner.key }.map(\.value).max() ?? 0
            guard confidence - runnerUp / intervalDuration >= minimumLead else { return nil }
        }
        return (winner.key, min(confidence, 1))
    }
}

/// Builds visible speaker runs from timed words. A word without speaker
/// evidence can stay unassigned without hiding a supported handoff nearby.
struct SpeakerAttributedRowBuilder: Sendable {
    /// The fraction of the recognized words supported by the winning slot,
    /// weighted by the model confidence and its coverage of each word.
    private static let minimumRunConfidence = 0.5
    private static let shortReplyConfidence = 0.65
    private static let shortReplyPauseFrames: Int64 = 6_400
    private static let clearReplyFrames: Int64 = 5_600
    private static let clearReplyConfidence = 0.9

    func rows(
        from row: MeetingTranscriptRow,
        turns: [DiarizedSpeakerTurn],
        sampleRate: Double = AudioTargetFormat.sampleRate
    ) -> [MeetingTranscriptRow] {
        guard row.source == .system, row.endFrame > row.startFrame, sampleRate > 0,
              !turns.isEmpty, let visibleRange = visibleOffsets(row: row) else { return [row] }

        let tokens = row.original.tokens.filter {
            $0.range.upperBound > visibleRange.lowerBound && $0.range.lowerBound < visibleRange.upperBound
        }
        guard !tokens.isEmpty else { return [row] }

        let aligner = SpeakerAttributionAligner()
        let words = tokens.map {
            aligner.wordAttribution(for: $0, rowStart: row.startFrame, turns: turns, sampleRate: sampleRate)
        }
        var speakers = Self.smoothedSpeakers(words)
        for index in speakers.indices.dropFirst() where Self.continuesPreviousWord(tokens[index].text) {
            speakers[index] = speakers[index - 1]
        }

        // Score display runs against the original evidence. Smoothing can
        // change the grouping, but it cannot make a word support another slot.
        for run in Self.runs(of: speakers) {
            let speaker = speakers[run.lowerBound]
            if Self.confidence(for: speaker, in: words[run]) < Self.minimumRunConfidence {
                speakers.replaceSubrange(run, with: repeatElement("others", count: run.count))
            }
        }

        let runs = Self.runs(of: speakers)
        let characters = Array(row.original.text)
        return runs.enumerated().map { index, run in
            let speaker = speakers[run.lowerBound]
            let lower = index == 0 ? visibleRange.lowerBound : tokens[run.lowerBound].range.lowerBound
            let upper = index == runs.count - 1 ? visibleRange.upperBound : tokens[run.upperBound].range.lowerBound
            let slice = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = words[run].filter { $0.speakerID != "others" }
            let start = index == 0 ? row.startFrame : words[run.lowerBound].startFrame
            let end = index == runs.count - 1 ? row.endFrame : words[run.upperBound - 1].endFrame

            if speaker == "others" {
                return MeetingTranscriptRow(
                    source: row.source, startFrame: start, endFrame: end,
                    text: slice, original: row.original, wordAttributions: evidence,
                    rawSlice: runs.count == 1 ? row.rawSlice : slice
                )
            }
            return row.attributed(
                speakerID: speaker, confidence: Self.confidence(for: speaker, in: words[run]),
                words: evidence, startFrame: start, endFrame: end, text: slice,
                rawSlice: runs.count == 1 ? row.rawSlice : slice
            )
        }
    }

    private static func confidence(for speaker: String, in words: ArraySlice<SpeakerWordAttribution>) -> Double {
        words.reduce(0) { $0 + ($1.speakerID == speaker ? $1.confidence : 0) } / Double(words.count)
    }

    /// Whisper writes "кого-то" as "кого" and "-то", and "Opus'а" as "Opus"
    /// and "'а". A turn never starts on such a piece: on 03.11 one row ended
    /// in "у кого" and the next began with "-то?".
    static func continuesPreviousWord(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return false }
        return first == "-" || first == "'" || first == "’"
    }

    /// A speaker run shorter than both of these is the diarizer wavering
    /// inside one voice, not a turn.
    ///
    /// On 28.10 a single remote speaker came back as "Почитай, | чи тобі все |
    /// в ньому зрозуміло | …", alternating speaker-1 and speaker-2 word by
    /// word: 153 of 266 rows held three words or fewer. Replayed on that
    /// meeting, these values leave 135 rows, 7 of them that short.
    static let minimumTurnWords = 4
    static let minimumTurnFrames: Int64 = 24_000

    /// A pause followed by strong evidence can mark a short answer. At a
    /// contested handoff, leave uncovered words explicitly unassigned.
    static func smoothedSpeakers(_ words: [SpeakerWordAttribution]) -> [String] {
        var speakers = words.map(\.speakerID)
        while true {
            let runs = runs(of: speakers)
            guard runs.count > 1 else { return speakers }
            var changed = false
            for (index, run) in runs.enumerated() {
                let first = run.lowerBound
                let last = run.upperBound - 1
                guard run.count < minimumTurnWords,
                      words[last].endFrame - words[first].startFrame < minimumTurnFrames else { continue }

                let previous = index > 0 ? runs[index - 1] : nil
                let next = index + 1 < runs.count ? runs[index + 1] : nil
                let previousSpeaker = previous.map { speakers[$0.lowerBound] }
                let nextSpeaker = next.map { speakers[$0.lowerBound] }
                let speaker = speakers[first]
                let pauseBefore = first > 0 ? words[first].startFrame - words[first - 1].endFrame : 0
                let pauseAfter = last + 1 < words.count ? words[last + 1].startFrame - words[last].endFrame : 0

                let replacement: String
                if speaker == "others" {
                    guard let previousSpeaker, previousSpeaker == nextSpeaker else { continue }
                    replacement = previousSpeaker
                } else {
                    let confidence = confidence(for: speaker, in: words[run])
                    let hasPause = max(pauseBefore, pauseAfter) >= shortReplyPauseFrames
                    let strongReply = confidence >= clearReplyConfidence
                        && words[last].endFrame - words[first].startFrame >= clearReplyFrames
                    guard !strongReply, !hasPause || confidence < shortReplyConfidence else { continue }
                    if previousSpeaker == "others" || nextSpeaker == "others" {
                        replacement = "others"
                    } else if let previous, let next {
                        replacement = speakers[(next.count > previous.count ? next : previous).lowerBound]
                    } else {
                        replacement = previousSpeaker ?? nextSpeaker ?? "others"
                    }
                }
                speakers.replaceSubrange(run, with: repeatElement(replacement, count: run.count))
                changed = true
                break
            }
            if !changed { return speakers }
        }
    }

    private static func runs(of speakers: [String]) -> [Range<Int>] {
        guard !speakers.isEmpty else { return [] }
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1...speakers.count where index == speakers.count || speakers[index] != speakers[start] {
            runs.append(start..<index)
            start = index
        }
        return runs
    }

    private func visibleOffsets(row: MeetingTranscriptRow) -> Range<Int>? {
        guard let range = row.original.text.range(of: row.text, options: .backwards) else { return nil }
        let lower = row.original.text.distance(from: row.original.text.startIndex, to: range.lowerBound)
        let upper = row.original.text.distance(from: row.original.text.startIndex, to: range.upperBound)
        return lower..<upper
    }
}

protocol SpeakerDiarizationService: Sendable {
    mutating func ingest(_ chunk: MeetingAudioChunk) -> [DiarizedSpeakerTurn]
    mutating func finish() -> [DiarizedSpeakerTurn]
}

/// Production fallback. It deliberately emits no hypotheses, leaving the
/// separately captured sources as `You` and `Others`.
struct UnavailableSpeakerDiarizationService: SpeakerDiarizationService {
    mutating func ingest(_ chunk: MeetingAudioChunk) -> [DiarizedSpeakerTurn] { [] }
    mutating func finish() -> [DiarizedSpeakerTurn] { [] }
}

/// Dependency-free, memory-only experiment for validating streaming plumbing,
/// clustering and alignment. Its hand-built acoustic fingerprint is not a
/// production speaker embedding and is therefore kept behind the corpus gate.
struct ExperimentalLocalSpeakerDiarizer: SpeakerDiarizationService {
    private struct Cluster: Sendable {
        var centroid: [Double]
        var count: Int
    }

    private let frameCount: Int
    private let maximumSpeakers: Int
    private let newSpeakerDistance: Double
    private var bufferedSamples: [Float] = []
    private var bufferedStartFrame: Int64?
    private var expectedFrame: Int64?
    private var clusters: [Cluster] = []

    init(frameCount: Int = 12_000, maximumSpeakers: Int = 3, newSpeakerDistance: Double = 0.32) {
        precondition(frameCount > 0 && maximumSpeakers > 0 && newSpeakerDistance > 0)
        self.frameCount = frameCount
        self.maximumSpeakers = maximumSpeakers
        self.newSpeakerDistance = newSpeakerDistance
    }

    mutating func ingest(_ chunk: MeetingAudioChunk) -> [DiarizedSpeakerTurn] {
        guard chunk.source == .system,
              chunk.sampleRate == AudioTargetFormat.sampleRate,
              !chunk.samples.isEmpty else { return [] }
        if let expectedFrame, abs(chunk.startFrame - expectedFrame) > 2 {
            bufferedSamples.removeAll(keepingCapacity: true)
            bufferedStartFrame = nil
        }
        if bufferedStartFrame == nil { bufferedStartFrame = chunk.startFrame }
        bufferedSamples.append(contentsOf: chunk.samples)
        expectedFrame = chunk.startFrame + Int64(chunk.samples.count)

        var turns: [DiarizedSpeakerTurn] = []
        while bufferedSamples.count >= frameCount, let start = bufferedStartFrame {
            let samples = Array(bufferedSamples.prefix(frameCount))
            bufferedSamples.removeFirst(frameCount)
            bufferedStartFrame = start + Int64(frameCount)
            if let turn = classify(samples: samples, startFrame: start) { turns.append(turn) }
        }
        return turns
    }

    mutating func finish() -> [DiarizedSpeakerTurn] {
        defer {
            bufferedSamples.removeAll(keepingCapacity: false)
            bufferedStartFrame = nil
            expectedFrame = nil
        }
        guard let start = bufferedStartFrame, bufferedSamples.count >= frameCount / 2,
              let turn = classify(samples: bufferedSamples, startFrame: start) else { return [] }
        return [turn]
    }

    mutating func diarizeOffline(samples: [Float], startFrame: Int64 = 0) -> [DiarizedSpeakerTurn] {
        var copy = ExperimentalLocalSpeakerDiarizer(
            frameCount: frameCount,
            maximumSpeakers: maximumSpeakers,
            newSpeakerDistance: newSpeakerDistance
        )
        let chunk = MeetingAudioChunk(
            source: .system,
            sequence: 0,
            startFrame: startFrame,
            sampleRate: AudioTargetFormat.sampleRate,
            samples: samples,
            isFinal: true
        )
        var turns = copy.ingest(chunk)
        turns.append(contentsOf: copy.finish())
        return turns
    }

    private mutating func classify(samples: [Float], startFrame: Int64) -> DiarizedSpeakerTurn? {
        guard let fingerprint = Self.fingerprint(samples), !fingerprint.isEmpty else { return nil }
        let distances = clusters.map { Self.distance(fingerprint, $0.centroid) }
        let nearest = distances.enumerated().min { $0.element < $1.element }
        let index: Int
        let confidence: Double
        if let nearest, nearest.element <= newSpeakerDistance || clusters.count >= maximumSpeakers {
            index = nearest.offset
            confidence = min(max(1 - nearest.element / max(newSpeakerDistance, 0.001), 0), 1)
            let oldCount = clusters[index].count
            let nextCount = oldCount + 1
            clusters[index].centroid = zip(clusters[index].centroid, fingerprint).map {
                ($0.0 * Double(oldCount) + $0.1) / Double(nextCount)
            }
            clusters[index].count = nextCount
        } else {
            index = clusters.count
            clusters.append(Cluster(centroid: fingerprint, count: 1))
            confidence = 0.5
        }
        return DiarizedSpeakerTurn(
            speakerID: "speaker-\(index + 1)",
            startFrame: startFrame,
            endFrame: startFrame + Int64(samples.count),
            confidence: confidence
        )
    }

    private static func fingerprint(_ samples: [Float]) -> [Double]? {
        guard !samples.isEmpty else { return nil }
        var squareSum = 0.0
        var crossings = 0
        for index in samples.indices {
            let value = Double(samples[index])
            squareSum += value * value
            if index > 0, (samples[index] >= 0) != (samples[index - 1] >= 0) { crossings += 1 }
        }
        let rms = sqrt(squareSum / Double(samples.count))
        guard rms >= 0.001 else { return nil }
        let zcr = Double(crossings) / Double(max(samples.count - 1, 1))
        var values = [min(max((log10(rms) + 3) / 3, 0), 1), zcr]
        for lag in [32, 48, 64, 80, 100, 128] where lag < samples.count {
            var numerator = 0.0
            var left = 0.0
            var right = 0.0
            for index in lag..<samples.count {
                let a = Double(samples[index])
                let b = Double(samples[index - lag])
                numerator += a * b
                left += a * a
                right += b * b
            }
            values.append(numerator / max(sqrt(left * right), 0.000_001))
        }
        return values
    }

    private static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        return sqrt(zip(lhs, rhs).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(lhs.count))
    }
}

enum DiarizationCorpusCategory: String, CaseIterable, Codable, Sendable {
    case overlaps
    case shortTurns
    case similarVoices
    case sharedRoomMicrophones
}

struct DiarizationCorpusMeasurement: Codable, Sendable, Equatable {
    let category: DiarizationCorpusCategory
    let recordingCount: Int
    let scoredDuration: TimeInterval
    let speakerErrorDuration: TimeInterval

    var speakerErrorRate: Double? {
        scoredDuration > 0 ? speakerErrorDuration / scoredDuration : nil
    }
}

struct DiarizationQualityGate: Sendable, Equatable {
    let minimumRecordingsPerCategory: Int
    let minimumDurationPerCategory: TimeInterval
    let maximumSpeakerErrorRate: Double

    init(
        minimumRecordingsPerCategory: Int = 10,
        minimumDurationPerCategory: TimeInterval = 600,
        maximumSpeakerErrorRate: Double = 0.20
    ) {
        self.minimumRecordingsPerCategory = minimumRecordingsPerCategory
        self.minimumDurationPerCategory = minimumDurationPerCategory
        self.maximumSpeakerErrorRate = maximumSpeakerErrorRate
    }

    func passes(_ measurements: [DiarizationCorpusMeasurement]) -> Bool {
        DiarizationCorpusCategory.allCases.allSatisfy { category in
            guard let value = measurements.first(where: { $0.category == category }),
                  let rate = value.speakerErrorRate,
                  value.recordingCount >= 0,
                  value.scoredDuration > 0,
                  value.speakerErrorDuration >= 0,
                  value.speakerErrorDuration <= value.scoredDuration else { return false }
            return value.recordingCount >= minimumRecordingsPerCategory
                && value.scoredDuration >= minimumDurationPerCategory
                && rate <= maximumSpeakerErrorRate
        }
    }
}
