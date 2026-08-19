import XCTest
@testable import LocalDictation

final class EnergyVoiceActivityDetectorTests: XCTestCase {
    private let sampleRate: Double = 16_000

    private func makeConfiguration(
        windowDuration: TimeInterval = 0.02,
        speechThreshold: Float = 0.05,
        silenceThreshold: Float = 0.01,
        activationWindows: Int = 3,
        trailingSilence: TimeInterval = 0.5,
        maximumDuration: TimeInterval = 5
    ) -> VoiceActivityConfiguration {
        VoiceActivityConfiguration(
            windowDuration: windowDuration,
            speechThreshold: speechThreshold,
            silenceThreshold: silenceThreshold,
            speechActivationWindows: activationWindows,
            trailingSilenceDuration: trailingSilence,
            maximumUtteranceDuration: maximumDuration
        )
    }

    private func frames(level: Float, duration: TimeInterval) -> [Float] {
        [Float](repeating: level, count: Int(duration * sampleRate))
    }

    func testSilenceNeverDeclaresSpeech() {
        var detector = EnergyVoiceActivityDetector(configuration: makeConfiguration(), sampleRate: sampleRate)
        let observation = detector.ingest(frames(level: 0.001, duration: 1.0))

        XCTAssertEqual(observation.state, .idle)
        XCTAssertNil(observation.speechStart)
        XCTAssertEqual(observation.elapsed, 1.0, accuracy: 0.001)
    }

    func testSpeechStartRequiresConsecutiveWindows() {
        var detector = EnergyVoiceActivityDetector(
            configuration: makeConfiguration(activationWindows: 3),
            sampleRate: sampleRate
        )

        // Two loud windows are not enough.
        var observation = detector.ingest(frames(level: 0.4, duration: 0.04))
        XCTAssertEqual(observation.state, .idle)
        XCTAssertNil(observation.speechStart)

        observation = detector.ingest(frames(level: 0.4, duration: 0.02))
        XCTAssertEqual(observation.state, .speaking)
        XCTAssertEqual(try XCTUnwrap(observation.speechStart), 0, accuracy: 0.001)
    }

    func testIsolatedLoudWindowsDoNotTriggerSpeech() {
        var detector = EnergyVoiceActivityDetector(
            configuration: makeConfiguration(activationWindows: 3),
            sampleRate: sampleRate
        )

        for _ in 0..<5 {
            detector.ingest(frames(level: 0.4, duration: 0.02))
            detector.ingest(frames(level: 0.001, duration: 0.02))
        }

        XCTAssertEqual(detector.observation.state, .idle)
    }

    func testTrailingSilenceEndsTheUtterance() {
        var detector = EnergyVoiceActivityDetector(
            configuration: makeConfiguration(trailingSilence: 0.5),
            sampleRate: sampleRate
        )

        detector.ingest(frames(level: 0.4, duration: 0.2))
        XCTAssertEqual(detector.observation.state, .speaking)

        var observation = detector.ingest(frames(level: 0.001, duration: 0.2))
        XCTAssertEqual(observation.state, .trailingSilence)
        XCTAssertEqual(observation.trailingSilence, 0.2, accuracy: 0.001)

        observation = detector.ingest(frames(level: 0.001, duration: 0.35))
        XCTAssertEqual(observation.state, .endedBySilence)
        XCTAssertGreaterThanOrEqual(observation.trailingSilence, 0.5)
        XCTAssertEqual(try XCTUnwrap(observation.speechStart), 0, accuracy: 0.001)
    }

    func testSpeechResumesAfterShortPause() {
        var detector = EnergyVoiceActivityDetector(
            configuration: makeConfiguration(trailingSilence: 0.5),
            sampleRate: sampleRate
        )

        detector.ingest(frames(level: 0.4, duration: 0.2))
        detector.ingest(frames(level: 0.001, duration: 0.2))
        XCTAssertEqual(detector.observation.state, .trailingSilence)

        let observation = detector.ingest(frames(level: 0.4, duration: 0.06))
        XCTAssertEqual(observation.state, .speaking)
        XCTAssertEqual(observation.trailingSilence, 0, accuracy: 0.0001)
    }

    func testHysteresisKeepsAmbiguousLevelsInTrailingSilence() {
        var detector = EnergyVoiceActivityDetector(
            configuration: makeConfiguration(speechThreshold: 0.05, silenceThreshold: 0.01, trailingSilence: 0.5),
            sampleRate: sampleRate
        )

        detector.ingest(frames(level: 0.4, duration: 0.2))
        detector.ingest(frames(level: 0.001, duration: 0.1))
        XCTAssertEqual(detector.observation.state, .trailingSilence)

        // Between both thresholds: neither speech nor accumulating silence.
        let observation = detector.ingest(frames(level: 0.03, duration: 0.1))
        XCTAssertEqual(observation.state, .trailingSilence)
        XCTAssertEqual(observation.trailingSilence, 0.1, accuracy: 0.001)
    }

    func testMaximumDurationIsTerminal() {
        var detector = EnergyVoiceActivityDetector(
            configuration: makeConfiguration(maximumDuration: 1),
            sampleRate: sampleRate
        )

        let observation = detector.ingest(frames(level: 0.4, duration: 1.5))
        XCTAssertEqual(observation.state, .endedByMaximumDuration)
        XCTAssertGreaterThanOrEqual(observation.elapsed, 1.0)
    }

    func testResetReturnsToInitialObservation() {
        var detector = EnergyVoiceActivityDetector(configuration: makeConfiguration(), sampleRate: sampleRate)
        detector.ingest(frames(level: 0.4, duration: 0.5))
        detector.reset()

        XCTAssertEqual(detector.observation, .initial)
    }

    func testIngestDoesNotModifyTheInputFrames() {
        var detector = EnergyVoiceActivityDetector(configuration: makeConfiguration(), sampleRate: sampleRate)
        let input = frames(level: 0.4, duration: 0.1)
        let copy = input
        _ = copy.withUnsafeBufferPointer { detector.ingest($0) }

        XCTAssertEqual(copy, input, "Phase 1 must never trim or rewrite captured frames")
    }

    func testConfigurationIsClampedToUsableRanges() {
        let configuration = VoiceActivityConfiguration(
            windowDuration: 0,
            speechThreshold: -1,
            silenceThreshold: 10,
            speechActivationWindows: 0,
            trailingSilenceDuration: 0,
            maximumUtteranceDuration: 0
        ).validated()

        XCTAssertGreaterThanOrEqual(configuration.windowDuration, 0.005)
        XCTAssertGreaterThan(configuration.speechThreshold, 0)
        XCTAssertLessThanOrEqual(configuration.silenceThreshold, configuration.speechThreshold)
        XCTAssertGreaterThanOrEqual(configuration.speechActivationWindows, 1)
        XCTAssertGreaterThanOrEqual(configuration.trailingSilenceDuration, 0.1)
        XCTAssertGreaterThanOrEqual(configuration.maximumUtteranceDuration, 1)
    }

    func testDefaultConfigurationSurvivesValidation() {
        XCTAssertEqual(VoiceActivityConfiguration.default.validated(), VoiceActivityConfiguration.default)
    }
}
