import AVFoundation
import CoreAudio
import XCTest
@testable import Witness

/// Rebinding happens inside a sentence, so the things that must survive it are
/// the buffer and the voice activity detector, not the audio unit.
final class InputRebindTests: XCTestCase {
    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        )
    }

    private func makeDiscreteFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let layout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        )
        return try XCTUnwrap(AVAudioFormat(streamDescription: &description, channelLayout: layout))
    }

    private func speech(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        offset: Int,
        amplitude: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                let value = sin(2 * .pi * 200 * Float(offset + frame) / Float(format.sampleRate)) * amplitude
                channels[channel][frame] = channel == 0 ? value : 0
            }
        }
        return buffer
    }

    /// The sentence is one buffer. A segment ending drains its resampler into
    /// that same buffer and the next segment appends to it, so a route change
    /// costs the gap and nothing else.
    func testTwoSegmentsLandInOneUtterance() throws {
        let sink = PCMCaptureSink(
            capacityFrames: AudioCaptureConfiguration.default.bufferCapacityFrames,
            detector: EnergyVoiceActivityDetector()
        )

        // Before the call page opened: one channel.
        let firstFormat = try makeFormat(sampleRate: 48_000, channels: 1)
        let first = try AudioFormatConverter(inputFormat: firstFormat)
        var expected = 0
        for index in 0..<10 {
            let buffer = try speech(format: firstFormat, frameCount: 4_800, offset: index * 4_800, amplitude: 0.5)
            let frames = try first.convert(buffer)
            expected += frames.count
            sink.ingest(frames)
        }
        let firstTail = try first.drain()
        expected += firstTail.count
        sink.ingest(firstTail)

        let afterFirstSegment = sink.snapshot()
        XCTAssertNotNil(afterFirstSegment.voiceActivity.speechStart, "The first segment heard speech")

        // After it opened: the same microphone, now three raw channels.
        let secondFormat = try makeDiscreteFormat(sampleRate: 48_000, channels: 3)
        let second = try AudioFormatConverter(inputFormat: secondFormat)
        for index in 0..<10 {
            let buffer = try speech(format: secondFormat, frameCount: 4_800, offset: index * 4_800, amplitude: 0.5)
            let frames = try second.convert(buffer)
            expected += frames.count
            sink.ingest(frames)
        }
        let secondTail = try second.drain()
        expected += secondTail.count
        sink.ingest(secondTail)

        let utterance = sink.finish(reason: .hotkeyRelease, rebindCount: 1)

        XCTAssertEqual(utterance.frameCount, expected, "Both segments' frames belong to the one utterance")
        XCTAssertEqual(Double(utterance.frameCount), 32_000, accuracy: 128, "Two seconds of speech at 16 kHz")
        XCTAssertEqual(
            utterance.voiceActivity.speechStart, afterFirstSegment.voiceActivity.speechStart,
            "Voice activity is the utterance's, so the rebind must not restart it"
        )
        XCTAssertGreaterThan(utterance.peakLevel, 0.3, "The second segment is not silence")
        XCTAssertEqual(utterance.rebindCount, 1)
    }

    /// The count is the only trace a rebind leaves: the user is told nothing,
    /// so a report has to be able to say it happened.
    func testTheRebindCountReachesTheUtteranceSummary() {
        let sink = PCMCaptureSink(capacityFrames: 16_000, detector: EnergyVoiceActivityDetector())
        let samples = [Float](repeating: 0.2, count: 1_600)
        samples.withUnsafeBufferPointer { sink.ingest($0) }

        let summary = UtteranceSummary(sink.finish(reason: .hotkeyRelease, rebindCount: 2))
        XCTAssertEqual(summary.rebindCount, 2)
    }

    func testARecordingThatNeverChangedRouteReportsNoRebinds() {
        let sink = PCMCaptureSink(capacityFrames: 16_000, detector: EnergyVoiceActivityDetector())
        XCTAssertEqual(UtteranceSummary(sink.finish(reason: .hotkeyRelease)).rebindCount, 0)
    }

    // MARK: - Collapsing a burst

    /// A Bluetooth or voice-processing switch arrives as dozens of notifications
    /// within milliseconds. Acting on each one would stop and restart the
    /// microphone dozens of times inside one sentence.
    func testABurstOfNotificationsCausesOneRebind() {
        let queue = DispatchQueue(label: "test.route")
        let fired = expectation(description: "the debounced event lands")
        let count = Counter()
        let debouncer = RouteChangeDebouncer(queue: queue, quietPeriod: 0.05) { _ in
            count.increment()
            fired.fulfill()
        }

        queue.async {
            for _ in 0..<30 { debouncer.submit(.boundDeviceFormatChanged) }
        }

        wait(for: [fired], timeout: 2)
        // Long enough that a second delivery would have arrived if one were queued.
        let settled = expectation(description: "nothing else arrives")
        queue.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(count.value, 1, "Thirty notifications are one route change")
    }

    func testTheMoreInformativeEventSurvivesTheBurst() {
        let queue = DispatchQueue(label: "test.route.precedence")
        let fired = expectation(description: "the debounced event lands")
        let received = EventBox()
        let debouncer = RouteChangeDebouncer(queue: queue, quietPeriod: 0.05) { event in
            received.value = event
            fired.fulfill()
        }

        queue.async {
            debouncer.submit(.deviceListChanged)
            debouncer.submit(.boundDeviceDied)
            debouncer.submit(.boundDeviceFormatChanged)
        }

        wait(for: [fired], timeout: 2)
        XCTAssertEqual(received.value, .boundDeviceDied)
    }

    // MARK: - The watchdog

    /// The only place a headset that answers without its microphone can be
    /// noticed: the callbacks arrive on time and carry bit-exact zeros, so
    /// nothing in the route reports anything.
    func testDigitalSilenceIsReportedOnceWhileItLasts() {
        let queue = DispatchQueue(label: "test.route.silence")
        let monitor = InputRouteMonitor(
            hardware: DeafHardware(),
            queue: queue,
            quietPeriod: 0.02,
            watchdogSilence: 10,
            watchdogInterval: 0.02,
            digitalSilenceLimit: 0.05
        )
        let count = Counter()
        let received = EventBox()
        let fired = expectation(description: "the silence is reported")
        fired.assertForOverFulfill = false

        monitor.start(
            device: 1,
            progress: {
                InputProgress(
                    lastCallbackUptime: ProcessInfo.processInfo.systemUptime,
                    digitalSilenceSeconds: 0.5
                )
            },
            onEvent: { event in
                received.value = event
                count.increment()
                fired.fulfill()
            }
        )

        wait(for: [fired], timeout: 2)
        let settled = expectation(description: "several more watchdog ticks pass")
        queue.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        monitor.stop()

        XCTAssertEqual(received.value, .boundDeviceDeliveredSilence)
        XCTAssertEqual(count.value, 1, "A device that keeps delivering zeros must not produce an event every tick")
    }

    func testADeviceThatDeliversSomethingIsNotReported() {
        let queue = DispatchQueue(label: "test.route.signal")
        let monitor = InputRouteMonitor(
            hardware: DeafHardware(),
            queue: queue,
            quietPeriod: 0.02,
            watchdogSilence: 10,
            watchdogInterval: 0.02,
            digitalSilenceLimit: 0.05
        )
        let count = Counter()

        monitor.start(
            device: 1,
            progress: {
                InputProgress(
                    lastCallbackUptime: ProcessInfo.processInfo.systemUptime,
                    digitalSilenceSeconds: nil
                )
            },
            onEvent: { _ in count.increment() }
        )

        let settled = expectation(description: "the watchdog ticks several times")
        queue.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        monitor.stop()

        XCTAssertEqual(count.value, 0)
    }

    func testCancellingStopsAPendingEvent() {
        let queue = DispatchQueue(label: "test.route.cancel")
        let count = Counter()
        let debouncer = RouteChangeDebouncer(queue: queue, quietPeriod: 0.05) { _ in count.increment() }

        queue.async {
            debouncer.submit(.defaultInputChanged)
            debouncer.cancel()
        }

        let settled = expectation(description: "the quiet period passes")
        queue.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(count.value, 0, "A recording that ended must not rebind afterwards")
    }
}

/// Hardware that registers no listeners, so the watchdog is the only thing that
/// can speak. Nothing here opens a device or asks for permission.
private struct DeafHardware: AudioHardware {
    func defaultInputDeviceID() -> AudioDeviceID? { 1 }
    func availableInputDevices() -> [SystemAudioInput.Device] { [] }
    func inputChannelCount(of device: AudioDeviceID) -> Int? { 1 }
    func nominalSampleRate(of device: AudioDeviceID) -> Double? { 48_000 }
    func isAlive(_ device: AudioDeviceID) -> Bool { true }
    func addListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioPropertyListenerToken? { nil }
    func removeListener(_ token: AudioPropertyListenerToken) {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: InputRouteEvent?
    var value: InputRouteEvent? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
