import Foundation

/// Deterministic energy/RMS baseline boundary detector.
///
/// The detector is a value type with no allocation in `ingest`, so the audio
/// thread can drive it directly. All timing is derived from frame counts rather
/// than wall-clock time, which makes the logic reproducible in tests.
struct EnergyVoiceActivityDetector: VoiceActivityDetector {
    let configuration: VoiceActivityConfiguration
    let sampleRate: Double

    private let windowFrames: Int
    private let activationFrames: Int
    private let trailingSilenceFrames: Int
    private let maximumFrames: Int

    private var squaredSum: Float = 0
    private var windowFill: Int = 0
    private var consecutiveSpeechWindows: Int = 0
    private var elapsedFrames: Int = 0
    private var silenceFrames: Int = 0
    private var speechStartFrame: Int?
    private var state: VoiceActivityState = .idle
    private var lastWindowRMS: Float = 0

    init(configuration: VoiceActivityConfiguration = .default, sampleRate: Double = AudioTargetFormat.sampleRate) {
        let validated = configuration.validated()
        self.configuration = validated
        self.sampleRate = sampleRate
        windowFrames = max(Int((validated.windowDuration * sampleRate).rounded()), 1)
        activationFrames = windowFrames * validated.speechActivationWindows
        trailingSilenceFrames = max(Int((validated.trailingSilenceDuration * sampleRate).rounded()), windowFrames)
        maximumFrames = max(Int((validated.maximumUtteranceDuration * sampleRate).rounded()), windowFrames)
    }

    var observation: VoiceActivityObservation {
        VoiceActivityObservation(
            state: state,
            speechStart: speechStartFrame.map { Double($0) / sampleRate },
            trailingSilence: Double(silenceFrames) / sampleRate,
            elapsed: Double(elapsedFrames) / sampleRate,
            lastWindowRMS: lastWindowRMS
        )
    }

    mutating func reset() {
        squaredSum = 0
        windowFill = 0
        consecutiveSpeechWindows = 0
        elapsedFrames = 0
        silenceFrames = 0
        speechStartFrame = nil
        state = .idle
        lastWindowRMS = 0
    }

    @discardableResult
    mutating func ingest(_ frames: UnsafeBufferPointer<Float>) -> VoiceActivityObservation {
        guard let base = frames.baseAddress, !frames.isEmpty else { return observation }

        var index = 0
        while index < frames.count {
            let take = min(windowFrames - windowFill, frames.count - index)
            var sum = squaredSum
            for offset in 0..<take {
                let sample = base[index + offset]
                sum += sample * sample
            }
            squaredSum = sum
            windowFill += take
            index += take
            elapsedFrames += take

            if windowFill == windowFrames {
                let meanSquare = squaredSum / Float(windowFrames)
                let rms = meanSquare > 0 ? meanSquare.squareRoot() : 0
                lastWindowRMS = rms
                squaredSum = 0
                windowFill = 0
                advance(withWindowRMS: rms)
            }

            if elapsedFrames >= maximumFrames {
                state = .endedByMaximumDuration
                return observation
            }
        }

        return observation
    }

    /// Applies one completed analysis window to the boundary state.
    private mutating func advance(withWindowRMS rms: Float) {
        guard !state.isTerminal else { return }

        switch state {
        case .idle:
            if rms >= configuration.speechThreshold {
                consecutiveSpeechWindows += 1
                if consecutiveSpeechWindows >= configuration.speechActivationWindows {
                    state = .speaking
                    speechStartFrame = max(elapsedFrames - activationFrames, 0)
                    silenceFrames = 0
                }
            } else {
                consecutiveSpeechWindows = 0
            }

        case .speaking:
            if rms < configuration.silenceThreshold {
                silenceFrames += windowFrames
                state = silenceFrames >= trailingSilenceFrames ? .endedBySilence : .trailingSilence
            } else {
                silenceFrames = 0
            }

        case .trailingSilence:
            if rms >= configuration.speechThreshold {
                silenceFrames = 0
                state = .speaking
            } else if rms < configuration.silenceThreshold {
                silenceFrames += windowFrames
                if silenceFrames >= trailingSilenceFrames {
                    state = .endedBySilence
                }
            }

        case .endedBySilence, .endedByMaximumDuration:
            break
        }
    }
}
