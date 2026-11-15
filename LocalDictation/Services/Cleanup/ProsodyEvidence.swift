import Accelerate
import Foundation

/// The pitch of one utterance, ten milliseconds at a time, for as long as the
/// utterance is being cleaned up.
///
/// Why it exists: in Russian and Ukrainian a yes/no question is very often
/// worded exactly like a statement ("Ты завтра придёшь?") and only the melody
/// says which it is. Whisper hears that melody and still writes a period about
/// half the time (docs/PUNCTUATION_BENCHMARK.md). A text model cannot hear it at
/// all. The audio is already in memory while the utterance is transcribed, so
/// the pitch costs a few tens of milliseconds and no new model.
///
/// Like `CleanupTimingEvidence` it is ephemeral and content-derived: it is held
/// for one cleanup, never persisted, logged, or sent anywhere.
struct ProsodyEvidence: Sendable, Equatable {
    /// Seconds between frames.
    static let hop: TimeInterval = 0.01

    /// Fundamental frequency per frame in Hz, zero where the frame is unvoiced.
    let f0: [Float]

    /// Median pitch of the voiced frames: the speaker's own reference, so the
    /// features below are relative to this voice rather than to a norm.
    let medianF0: Float?

    init(f0: [Float]) {
        self.f0 = f0
        let voiced = f0.filter { $0 > 0 }.sorted()
        medianF0 = voiced.isEmpty ? nil : voiced[voiced.count / 2]
    }

    /// Pitch relative to the speaker's median, in semitones, over voiced
    /// frames between two times.
    func semitones(from start: TimeInterval, to end: TimeInterval) -> [Float] {
        guard let medianF0, medianF0 > 0, end > start else { return [] }
        let first = max(0, Int((start / Self.hop).rounded(.down)))
        let last = min(f0.count, Int((end / Self.hop).rounded(.up)))
        guard first < last else { return [] }
        return f0[first..<last].compactMap { value in
            value > 0 ? 12 * log2(value / medianF0) : nil
        }
    }

    /// The melody of the last stretch before `end`, where a sentence's
    /// question or statement contour lives.
    func ending(at end: TimeInterval) -> SentenceEndingProsody? {
        let window = semitones(from: end - SentenceEndingProsody.window, to: end + 0.15)
        guard window.count >= SentenceEndingProsody.minimumVoicedFrames else { return nil }
        let sorted = window.sorted()
        let peak = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let tailFrames = window.suffix(6).sorted()
        let tail = tailFrames[tailFrames.count / 2]
        let before = semitones(from: end - 2.0, to: end - SentenceEndingProsody.window).sorted()
        let local = before.isEmpty ? 0 : before[before.count / 2]
        let highest = window.indices.max { window[$0] < window[$1] } ?? 0
        let position = window.count > 1 ? Float(highest) / Float(window.count - 1) : 0
        return SentenceEndingProsody(peak: peak, tail: tail, rise: peak - local, peakPosition: position)
    }
}

/// Three numbers about how a sentence ends, all in semitones against the
/// speaker's median pitch.
struct SentenceEndingProsody: Sendable, Equatable {
    /// How far back from the last word's end the contour is read.
    static let window: TimeInterval = 0.7
    static let minimumVoicedFrames = 6

    /// The high point of the ending (90th percentile, robust to one octave
    /// error).
    let peak: Float
    /// Where the voice is at the very end.
    let tail: Float
    /// The peak over the pitch of the two seconds before the ending.
    let rise: Float
    /// Where in the ending the highest voiced frame falls, 0 at its start and
    /// 1 at its end. A statement that starts high and falls has its peak
    /// early; a question's rise comes late.
    var peakPosition: Float = 0
}

/// Pitch tracking with the YIN difference function, over Accelerate.
///
/// One 32 ms frame every 10 ms, 70 to 400 Hz, which covers speaking voices
/// without reaching into the harmonics. Thirty seconds of speech is about
/// three thousand frames and tens of milliseconds on an M1.
enum PitchTracker {
    static let frameLength = 512
    static let minimumF0: Float = 70
    static let maximumF0: Float = 400
    /// YIN's absolute threshold on the cumulative mean normalized difference.
    static let threshold: Float = 0.15
    /// Above this the frame is aperiodic: noise or a voiceless consonant.
    static let aperiodicity: Float = 0.35
    /// Longer utterances are analyzed only up to here; the tail of a
    /// two-minute dictation is not worth a quarter of a second.
    static let maximumSeconds: Double = 120

    static func evidence(samples: [Float], sampleRate: Double) -> ProsodyEvidence? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let rate = Float(sampleRate)
        let minimumLag = Int((rate / maximumF0).rounded(.down))
        let maximumLag = Int((rate / minimumF0).rounded(.up))
        let hop = Int((ProsodyEvidence.hop * sampleRate).rounded())
        let usable = min(samples.count, Int(maximumSeconds * sampleRate))
        guard usable >= frameLength + maximumLag + 1, hop > 0 else { return nil }

        let frameCount = (usable - frameLength - maximumLag) / hop + 1
        var energies = [Float](repeating: 0, count: frameCount)
        var pitches = [Float](repeating: 0, count: frameCount)
        var difference = [Float](repeating: 0, count: maximumLag + 1)
        var cross = [Float](repeating: 0, count: maximumLag + 1)

        // Running sums of squares, so the energy of any window is one
        // subtraction rather than a pass over it.
        var squares = [Double](repeating: 0, count: usable + 1)
        for index in 0..<usable {
            squares[index + 1] = squares[index] + Double(samples[index] * samples[index])
        }

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in 0..<frameCount {
                let offset = frame * hop
                let energy = Float(squares[offset + frameLength] - squares[offset])
                energies[frame] = energy / Float(frameLength)

                // r(τ) = Σ x_j x_{j+τ} for every lag in one correlation, then
                // d(τ) = Σ x_j² + Σ x_{j+τ}² − 2 r(τ).
                cross.withUnsafeMutableBufferPointer { result in
                    vDSP_conv(
                        base + offset, 1,
                        base + offset, 1,
                        result.baseAddress!, 1,
                        vDSP_Length(maximumLag + 1),
                        vDSP_Length(frameLength)
                    )
                }
                for lag in 1...maximumLag {
                    let shifted = Float(squares[offset + lag + frameLength] - squares[offset + lag])
                    difference[lag] = energy + shifted - 2 * cross[lag]
                }
                pitches[frame] = Self.period(in: &difference, minimumLag: minimumLag, maximumLag: maximumLag)
                    .map { rate / $0 } ?? 0
            }
        }

        // Frames far below the loud part of the utterance are room noise or
        // breath, whatever their periodicity says.
        let loud = energies.sorted()[min(frameCount - 1, Int(Double(frameCount) * 0.95))]
        let floor = max(1e-6, loud * 0.02)
        for frame in 0..<frameCount where energies[frame] < floor {
            pitches[frame] = 0
        }
        return ProsodyEvidence(f0: Self.smoothed(pitches))
    }

    /// The period in samples, refined between lags, or nil when the frame is
    /// not periodic enough to have one.
    private static func period(in difference: inout [Float], minimumLag: Int, maximumLag: Int) -> Float? {
        // Cumulative mean normalized difference, in place from lag 1.
        var running: Float = 0
        difference[0] = 1
        for lag in 1...maximumLag {
            running += difference[lag]
            difference[lag] = running > 0 ? difference[lag] * Float(lag) / running : 1
        }

        var chosen: Int?
        var lag = minimumLag
        while lag < maximumLag {
            if difference[lag] < threshold {
                while lag + 1 < maximumLag, difference[lag + 1] < difference[lag] { lag += 1 }
                chosen = lag
                break
            }
            lag += 1
        }
        if chosen == nil {
            var best = minimumLag
            for candidate in minimumLag...maximumLag where difference[candidate] < difference[best] {
                best = candidate
            }
            guard difference[best] < aperiodicity else { return nil }
            chosen = best
        }
        guard let tau = chosen else { return nil }

        // Parabolic interpolation around the minimum.
        guard tau > 1, tau < maximumLag else { return Float(tau) }
        let left = difference[tau - 1]
        let centre = difference[tau]
        let right = difference[tau + 1]
        let denominator = left + right - 2 * centre
        guard abs(denominator) > 1e-9 else { return Float(tau) }
        return Float(tau) + 0.5 * (left - right) / denominator
    }

    /// A five-frame median over voiced runs, which removes single-frame octave
    /// jumps without moving a real contour.
    private static func smoothed(_ track: [Float]) -> [Float] {
        guard track.count >= 5 else { return track }
        var result = track
        for index in 2..<(track.count - 2) where track[index] > 0 {
            let neighbourhood = track[(index - 2)...(index + 2)].filter { $0 > 0 }.sorted()
            if neighbourhood.count >= 3 { result[index] = neighbourhood[neighbourhood.count / 2] }
        }
        return result
    }
}
