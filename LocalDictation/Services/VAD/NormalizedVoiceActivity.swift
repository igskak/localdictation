import Foundation

/// Voice activity recomputed on a gain-normalized copy of a finished utterance.
///
/// The live detector runs on the samples as they arrived. While another app
/// holds Apple voice processing, those samples come from a raw microphone array
/// about 30 dB below the processed channel and never clear `speechThreshold`
/// (0.02 RMS, about -34 dBFS). Recognition copes with that — measured at 30 dB
/// attenuation across the four verified languages, the word error rate did not
/// move — so the only thing that breaks is the notice the app shows when a
/// press produced no text: it would say the microphone never heard speech,
/// which is not what happened.
///
/// Nothing here touches recognition or the real-time path. It runs once, off
/// the audio thread, on a finished utterance, and answers one question: did
/// this Mac hear speech?
enum NormalizedVoiceActivity {
    /// Where the loudest sample is put: -1 dBFS, leaving headroom rather than
    /// clipping at full scale.
    static let targetPeak: Float = 0.891
    /// The most gain that may be applied. Past this the recording is so far
    /// below normal that amplified room noise and quiet speech are the same
    /// signal, and guessing between them is worse than not answering.
    static let maximumGainDecibels: Double = 40

    /// A recomputed observation, or `nil` when the recording was too quiet for
    /// the answer to mean anything.
    ///
    /// `nil` is deliberately conservative: the caller keeps the live detector's
    /// answer, which for an empty result is "nothing was heard". A recording
    /// that needed more than the cap to reach `targetPeak` is one where the
    /// loudest moment is still near the noise floor — normalizing it would
    /// lift room noise past the speech threshold and turn a muted microphone
    /// into "nothing was recognized", which sends the user the wrong way.
    static func observation(
        for utterance: CapturedUtterance,
        configuration: VoiceActivityConfiguration = .default
    ) -> VoiceActivityObservation? {
        guard !utterance.samples.isEmpty else { return nil }

        var peak: Float = 0
        for sample in utterance.samples { peak = max(peak, abs(sample)) }
        guard peak > 0, peak < targetPeak else { return nil }

        let gain = targetPeak / peak
        let maximumGain = Float(pow(10, maximumGainDecibels / 20))
        guard gain <= maximumGain else { return nil }

        var detector = EnergyVoiceActivityDetector(
            configuration: configuration,
            sampleRate: utterance.sampleRate
        )
        // One window at a time, so the detector sees the same shape it would
        // have seen live rather than one buffer the size of the utterance.
        var scaled = [Float](repeating: 0, count: min(4_096, utterance.samples.count))
        var index = 0
        while index < utterance.samples.count {
            let count = min(scaled.count, utterance.samples.count - index)
            for offset in 0..<count {
                scaled[offset] = utterance.samples[index + offset] * gain
            }
            scaled.withUnsafeBufferPointer { buffer in
                detector.ingest(UnsafeBufferPointer(rebasing: buffer[0..<count]))
            }
            index += count
        }
        return detector.observation
    }

    /// Whether this Mac heard speech, normalizing first when that is safe.
    ///
    /// The live answer is trusted whenever it already found speech: the
    /// normalized pass exists to rescue quiet recordings, never to overrule a
    /// detector that heard something.
    static func heardSpeech(
        in utterance: CapturedUtterance,
        configuration: VoiceActivityConfiguration = .default
    ) -> Bool {
        if utterance.voiceActivity.speechStart != nil { return true }
        return observation(for: utterance, configuration: configuration)?.speechStart != nil
    }
}
