import Foundation
import XCTest
@testable import Witness

/// Whether the app may say "nothing was heard".
///
/// Measured at 30 dB attenuation across German, English, Russian and Ukrainian,
/// recognition did not lose anything, so a quiet raw microphone array is left
/// alone on its way to the engine. The one thing that does break at that level
/// is the notice after an empty result: the live detector never clears its
/// speech threshold, and the app would blame a microphone that was working.
final class NormalizedVoiceActivityTests: XCTestCase {
    private func utterance(
        _ samples: [Float],
        speechStart: TimeInterval? = nil
    ) -> CapturedUtterance {
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        return CapturedUtterance(
            samples: samples,
            sampleRate: AudioTargetFormat.sampleRate,
            peakLevel: peak,
            droppedFrameCount: 0,
            voiceActivity: VoiceActivityObservation(
                state: speechStart == nil ? .idle : .speaking,
                speechStart: speechStart,
                trailingSilence: 0,
                elapsed: Double(samples.count) / AudioTargetFormat.sampleRate,
                lastWindowRMS: 0
            ),
            endReason: .hotkeyRelease
        )
    }

    /// Speech, then quiet, then speech — the shape a sentence has.
    private func speech(seconds: Double, amplitude: Float) -> [Float] {
        let rate = AudioTargetFormat.sampleRate
        let count = Int(seconds * rate)
        return (0..<count).map { frame in
            let second = Double(frame) / rate
            // A gap in the middle so the detector has silence to contrast against.
            let speaking = second < seconds * 0.4 || second > seconds * 0.6
            guard speaking else { return 0 }
            return sin(2 * .pi * 180 * Float(frame) / Float(rate)) * amplitude
        }
    }

    private func noise(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * AudioTargetFormat.sampleRate)
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    // MARK: - The case this exists for

    /// A raw microphone array during someone else's call: real speech, about
    /// 30 dB below the processed channel, which never clears the 0.02 RMS
    /// threshold on its way past the live detector.
    func testQuietSpeechIsHeardOnceNormalized() {
        let quiet = speech(seconds: 3, amplitude: 0.016)
        let recording = utterance(quiet)

        XCTAssertNil(
            recording.voiceActivity.speechStart,
            "Precondition: the live detector does not hear this, which is the bug"
        )
        XCTAssertTrue(NormalizedVoiceActivity.heardSpeech(in: recording))
    }

    func testNormalSpeechIsUnaffected() {
        let recording = utterance(speech(seconds: 3, amplitude: 0.5), speechStart: 0.1)
        XCTAssertTrue(NormalizedVoiceActivity.heardSpeech(in: recording))
    }

    /// The normalized pass rescues quiet recordings; it never overrules a
    /// detector that already heard something.
    func testALiveAnswerOfSpeechIsTrustedWithoutNormalizing() {
        let recording = utterance([Float](repeating: 0, count: 16_000), speechStart: 0.2)
        XCTAssertTrue(NormalizedVoiceActivity.heardSpeech(in: recording))
    }

    // MARK: - Where it must refuse to answer

    /// Digital silence has no peak to normalize towards.
    func testTrueSilenceIsStillSilence() {
        let recording = utterance([Float](repeating: 0, count: 32_000))
        XCTAssertNil(NormalizedVoiceActivity.observation(for: recording))
        XCTAssertFalse(NormalizedVoiceActivity.heardSpeech(in: recording))
    }

    /// The failure this guard exists for: a muted microphone's noise floor,
    /// amplified to -1 dBFS, would clear the speech threshold and the app would
    /// say "nothing was recognized" to someone whose microphone was off. Past
    /// the gain cap the answer is refused and the conservative one stands.
    func testANoiseFloorTooFarDownIsNotAmplifiedIntoSpeech() {
        // About -80 dBFS: below the raw array's speaking range, inside the
        // range measured for a silent one.
        let recording = utterance(noise(seconds: 3, amplitude: 0.0001))

        XCTAssertNil(
            NormalizedVoiceActivity.observation(for: recording),
            "More gain than the cap means the loudest moment is still the noise floor"
        )
        XCTAssertFalse(NormalizedVoiceActivity.heardSpeech(in: recording))
    }

    func testTheGainCapIsWhereTheRefusalHappens() {
        // Needs about 32 dB to reach the target, inside the 40 dB cap.
        let inside = utterance(speech(seconds: 3, amplitude: 0.022))
        XCTAssertNotNil(NormalizedVoiceActivity.observation(for: inside))

        // Needs about 59 dB, beyond it.
        let outside = utterance(speech(seconds: 3, amplitude: 0.001))
        XCTAssertNil(NormalizedVoiceActivity.observation(for: outside))
    }

    func testAnEmptyRecordingHasNothingToNormalize() {
        XCTAssertNil(NormalizedVoiceActivity.observation(for: utterance([])))
    }

    // MARK: - What the summary carries

    func testTheSummaryCarriesTheNormalizedAnswer() {
        let recording = utterance(speech(seconds: 3, amplitude: 0.016))
        let summary = UtteranceSummary(
            recording,
            heardSpeech: NormalizedVoiceActivity.heardSpeech(in: recording)
        )

        XCTAssertNil(summary.speechStart, "The live timing is still reported as it was")
        XCTAssertTrue(summary.heardSpeech, "The answer the notice uses is the normalized one")
    }

    func testTheSummaryDefaultsToTheLiveAnswer() {
        let recording = utterance(speech(seconds: 3, amplitude: 0.016))
        XCTAssertFalse(UtteranceSummary(recording).heardSpeech)
    }
}
