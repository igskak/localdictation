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

        let words = row.original.tokens.compactMap { token -> SpeakerWordAttribution? in
            let start = row.startFrame + Int64((max(token.start, 0) * sampleRate).rounded())
            let end = row.startFrame + Int64((max(token.end, token.start) * sampleRate).rounded())
            guard let value = attribution(start: start, end: max(end, start + 1), turns: turns) else { return nil }
            return SpeakerWordAttribution(
                text: token.text,
                startFrame: start,
                endFrame: max(end, start + 1),
                speakerID: value.speakerID,
                confidence: value.confidence
            )
        }
        return SpeakerAlignment(speakerID: segment.speakerID, confidence: segment.confidence, words: words)
    }

    private func attribution(
        start: Int64,
        end: Int64,
        turns: [DiarizedSpeakerTurn]
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
        guard let winner = durationBySpeaker.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) else { return nil }
        let intervalDuration = Double(end - start)
        let coverage = winner.value / intervalDuration
        let turnConfidence = weightedConfidenceBySpeaker[winner.key, default: 0] / winner.value
        return (winner.key, min(max(coverage * turnConfidence, 0), 1))
    }
}

/// Turns the word-level result into visible speaker runs without rewriting the
/// recognized words. If even one visible token cannot be attributed, the
/// original row is retained with a segment-level hypothesis instead of
/// dropping or inventing text.
struct SpeakerAttributedRowBuilder: Sendable {
    private struct MatchedWord {
        let token: TranscriptToken
        let attribution: SpeakerWordAttribution
    }

    func rows(
        from row: MeetingTranscriptRow,
        turns: [DiarizedSpeakerTurn],
        sampleRate: Double = AudioTargetFormat.sampleRate
    ) -> [MeetingTranscriptRow] {
        guard let alignment = SpeakerAttributionAligner().align(
            row: row,
            turns: turns,
            sampleRate: sampleRate
        ) else { return [row] }
        guard row.source == .system else { return [row] }

        let visibleRange = visibleOffsets(row: row)
        let visibleTokens = row.original.tokens.filter {
            $0.range.upperBound > visibleRange.lowerBound && $0.range.lowerBound < visibleRange.upperBound
        }
        var remaining = alignment.words
        let matched: [MatchedWord] = visibleTokens.compactMap { token in
            let start = row.startFrame + Int64((max(token.start, 0) * sampleRate).rounded())
            let end = row.startFrame + Int64((max(token.end, token.start) * sampleRate).rounded())
            guard let index = remaining.firstIndex(where: {
                $0.startFrame == start && $0.endFrame == max(end, start + 1) && $0.text == token.text
            }) else { return nil }
            return MatchedWord(token: token, attribution: remaining.remove(at: index))
        }

        guard !visibleTokens.isEmpty, matched.count == visibleTokens.count else {
            return [row.attributed(
                speakerID: alignment.speakerID,
                confidence: alignment.confidence,
                words: alignment.words
            )]
        }

        var groups: [[MatchedWord]] = []
        for word in matched {
            if groups.last?.last?.attribution.speakerID == word.attribution.speakerID {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        guard groups.count > 1 else {
            return [row.attributed(
                speakerID: alignment.speakerID,
                confidence: alignment.confidence,
                words: alignment.words
            )]
        }

        let characters = Array(row.original.text)
        return groups.enumerated().compactMap { index, group in
            guard let first = group.first, let last = group.last else { return nil }
            let lower = max(first.token.range.lowerBound, visibleRange.lowerBound)
            let nextLower = groups.indices.contains(index + 1)
                ? groups[index + 1][0].token.range.lowerBound
                : visibleRange.upperBound
            let upper = min(max(nextLower, lower), characters.count)
            guard lower < upper else { return nil }
            let text = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let words = group.map(\.attribution)
            let confidence = words.reduce(0) { $0 + $1.confidence } / Double(words.count)
            return row.attributed(
                speakerID: first.attribution.speakerID,
                confidence: confidence,
                words: words,
                startFrame: first.attribution.startFrame,
                endFrame: last.attribution.endFrame,
                text: text
            )
        }
    }

    private func visibleOffsets(row: MeetingTranscriptRow) -> Range<Int> {
        guard let range = row.original.text.range(of: row.text, options: .backwards) else {
            return 0..<row.original.text.count
        }
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
