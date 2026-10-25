import Foundation

/// Cleans a diarizer's raw turns before any of them reach a transcript, and
/// refuses to label at all when the result is not trustworthy.
///
/// The first real file (50 minutes, one room microphone, several people) came
/// back as 489 rows with 342 speaker changes, 94% of the time on one speaker,
/// single words such as "скрипт" or "будь" on their own row under a speaker
/// that the model itself gave a confidence of 0.1-0.4. Showing that as it is
/// reads as a finding. Three rules, applied to the turns and not to the rows so
/// that a sentence is never cut by a flicker:
///
/// 1. neighbouring turns of one speaker are joined across short gaps;
/// 2. a turn shorter than `minimumRunSeconds`, and every turn of a speaker who
///    barely speaks, is absorbed by the longer neighbour;
/// 3. for a finished recording, if one voice takes almost all the time or the
///    model's own confidence is low, no labels are returned and the rows stay
///    as they were recognised.
///
/// The thresholds are judgement, not measurement: nothing here has been tuned
/// against consented recordings, and `docs/FILE_TRANSCRIPTION_PLAN.md` says so.
struct SpeakerLabelPolicy: Sendable, Equatable {
    var minimumRunSeconds = 3.0
    var mergeGapSeconds = 1.0
    /// A speaker below both limits is treated as noise, not a participant.
    var rareSpeakerShare = 0.05
    var rareSpeakerSeconds = 20.0
    var maximumDominantShare = 0.90
    var minimumMeanConfidence = 0.35

    static let standard = SpeakerLabelPolicy()

    enum Doubt: String, Sendable, Equatable {
        /// One voice has nearly all the speech, so there is nothing to tell apart.
        case oneVoiceDominates
        case lowConfidence
    }

    struct Refinement: Sendable, Equatable {
        let turns: [DiarizedSpeakerTurn]
        /// Nil when the labels may be shown.
        let doubt: Doubt?
        var isReliable: Bool { doubt == nil }
    }

    /// `finished` is true for a complete recording. A live meeting only has the
    /// first minutes, where one voice dominating means nothing yet, so it gets
    /// the smoothing but not the refusal.
    func refine(_ raw: [DiarizedSpeakerTurn], sampleRate: Double = 16_000, finished: Bool) -> Refinement {
        let ordered = raw.filter { $0.endFrame > $0.startFrame }.sorted { $0.startFrame < $1.startFrame }
        guard !ordered.isEmpty else { return Refinement(turns: [], doubt: finished ? .oneVoiceDominates : nil) }

        let meanConfidence = Self.weightedConfidence(ordered)
        var turns = merged(ordered, sampleRate: sampleRate)
        absorbShortTurns(&turns, sampleRate: sampleRate)
        absorbRareSpeakers(&turns, sampleRate: sampleRate)
        turns = merged(turns, sampleRate: sampleRate, ignoreGap: true)

        guard finished else { return Refinement(turns: turns, doubt: nil) }
        let shares = talkShares(turns)
        if (shares.values.max() ?? 1) > maximumDominantShare {
            return Refinement(turns: [], doubt: .oneVoiceDominates)
        }
        if meanConfidence < minimumMeanConfidence {
            return Refinement(turns: [], doubt: .lowConfidence)
        }
        return Refinement(turns: turns, doubt: nil)
    }

    // MARK: - Steps

    private func merged(_ turns: [DiarizedSpeakerTurn], sampleRate: Double, ignoreGap: Bool = false) -> [DiarizedSpeakerTurn] {
        let gap = Int64(mergeGapSeconds * sampleRate)
        var result: [DiarizedSpeakerTurn] = []
        for turn in turns {
            if let last = result.last, last.speakerID == turn.speakerID,
               ignoreGap || turn.startFrame - last.endFrame <= gap {
                result[result.count - 1] = Self.join(last, turn)
            } else {
                result.append(turn)
            }
        }
        return result
    }

    private func absorbShortTurns(_ turns: inout [DiarizedSpeakerTurn], sampleRate: Double) {
        let limit = Int64(minimumRunSeconds * sampleRate)
        var guardRounds = turns.count * 2 + 4
        while guardRounds > 0, turns.count > 1 {
            guardRounds -= 1
            guard let index = turns.indices
                .filter({ turns[$0].endFrame - turns[$0].startFrame < limit })
                .min(by: { length(turns[$0]) < length(turns[$1]) }) else { return }
            absorb(index, into: &turns)
        }
    }

    private func absorbRareSpeakers(_ turns: inout [DiarizedSpeakerTurn], sampleRate: Double) {
        let total = turns.reduce(Int64(0)) { $0 + length($1) }
        guard total > 0 else { return }
        let seconds = Dictionary(grouping: turns, by: \.speakerID).mapValues { $0.reduce(Int64(0)) { $0 + length($1) } }
        let rare = Set(seconds.filter {
            Double($0.value) / Double(total) < rareSpeakerShare && Double($0.value) / sampleRate < rareSpeakerSeconds
        }.keys)
        guard !rare.isEmpty, rare.count < seconds.count else { return }
        var guardRounds = turns.count * 2 + 4
        while guardRounds > 0, turns.count > 1, let index = turns.firstIndex(where: { rare.contains($0.speakerID) }) {
            guardRounds -= 1
            absorb(index, into: &turns, avoiding: rare)
        }
    }

    /// Hands a turn to the longer of its neighbours and joins the two, so the
    /// stretch in between belongs to somebody instead of nobody.
    private func absorb(_ index: Int, into turns: inout [DiarizedSpeakerTurn], avoiding avoided: Set<String> = []) {
        let candidates = [index - 1, index + 1].filter { turns.indices.contains($0) && !avoided.contains(turns[$0].speakerID) }
        guard let target = candidates.max(by: { length(turns[$0]) < length(turns[$1]) }) else {
            // Only rare neighbours: leave the turn to the next round's sweep.
            if let fallback = [index - 1, index + 1].first(where: { turns.indices.contains($0) }) {
                turns[index] = DiarizedSpeakerTurn(speakerID: turns[fallback].speakerID, startFrame: turns[index].startFrame,
                                                   endFrame: turns[index].endFrame, confidence: turns[index].confidence)
                turns = merged(turns, sampleRate: 1, ignoreGap: true)
            }
            return
        }
        let lower = min(index, target), upper = max(index, target)
        let joined = Self.join(turns[lower], turns[upper], speaker: turns[target].speakerID)
        turns.replaceSubrange(lower...upper, with: [joined])
        turns = merged(turns, sampleRate: 1, ignoreGap: true)
    }

    private func length(_ turn: DiarizedSpeakerTurn) -> Int64 { turn.endFrame - turn.startFrame }

    private func talkShares(_ turns: [DiarizedSpeakerTurn]) -> [String: Double] {
        let total = Double(turns.reduce(Int64(0)) { $0 + length($1) })
        guard total > 0 else { return [:] }
        return Dictionary(grouping: turns, by: \.speakerID).mapValues { Double($0.reduce(Int64(0)) { $0 + length($1) }) / total }
    }

    private static func weightedConfidence(_ turns: [DiarizedSpeakerTurn]) -> Double {
        let total = turns.reduce(0.0) { $0 + Double($1.endFrame - $1.startFrame) }
        guard total > 0 else { return 0 }
        return turns.reduce(0.0) { $0 + Double($1.endFrame - $1.startFrame) * min(max($1.confidence, 0), 1) } / total
    }

    private static func join(_ a: DiarizedSpeakerTurn, _ b: DiarizedSpeakerTurn, speaker: String? = nil) -> DiarizedSpeakerTurn {
        let lengthA = Double(a.endFrame - a.startFrame), lengthB = Double(b.endFrame - b.startFrame)
        let confidence = lengthA + lengthB > 0 ? (a.confidence * lengthA + b.confidence * lengthB) / (lengthA + lengthB) : a.confidence
        return DiarizedSpeakerTurn(speakerID: speaker ?? a.speakerID, startFrame: min(a.startFrame, b.startFrame),
                                   endFrame: max(a.endFrame, b.endFrame), confidence: confidence)
    }
}
