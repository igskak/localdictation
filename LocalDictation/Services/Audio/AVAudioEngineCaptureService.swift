import AVFoundation
import Foundation

/// `AVAudioEngine`-backed capture.
///
/// The input tap converts device buffers to mono Float32 16 kHz and appends them
/// to a bounded in-memory sink. The callback performs no allocation beyond the
/// converter's reused output buffer, never logs samples, and never writes to disk.
/// Engine lifecycle is guarded by an unfair lock because `AVAudioEngine` is not
/// `Sendable` and start/stop can arrive from different tasks.
final class AVAudioEngineCaptureService: AudioCaptureService, @unchecked Sendable {
    private struct Session {
        let sink: PCMCaptureSink
        let converter: AudioFormatConverter
        let format: CaptureFormatDescription
    }

    private let lock = UnfairLock()
    private let engine = AVAudioEngine()
    private var session: Session?
    private var configurationObserver: NSObjectProtocol?
    private var interruptionHandler: (@Sendable (AudioCaptureError) -> Void)?

    init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start(
        configuration: AudioCaptureConfiguration,
        onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
    ) async throws -> CaptureFormatDescription {
        // Tear down any previous session before touching the engine graph.
        teardown()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let device = SystemAudioInput.defaultInputDevice()
        let converter = try AudioFormatConverter(inputFormat: inputFormat)
        let detector = EnergyVoiceActivityDetector(
            configuration: configuration.voiceActivity,
            sampleRate: AudioTargetFormat.sampleRate
        )
        let sink = PCMCaptureSink(
            capacityFrames: configuration.bufferCapacityFrames,
            sampleRate: AudioTargetFormat.sampleRate,
            detector: detector
        )
        let format = CaptureFormatDescription(
            inputDeviceName: device?.name,
            inputSampleRate: inputFormat.sampleRate,
            inputChannelCount: Int(inputFormat.channelCount),
            outputSampleRate: AudioTargetFormat.sampleRate,
            outputChannelCount: AudioTargetFormat.channelCount,
            bufferCapacityFrames: sink.capacityFrames
        )

        lock.withLock {
            session = Session(sink: sink, converter: converter, format: format)
            interruptionHandler = onInterruption
        }

        observeConfigurationChanges()

        // The tap closure runs on a real-time audio thread.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.handleTap(buffer: buffer, sink: sink, converter: converter)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            teardown()
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        Log.audio.info(
            "Capture started: input \(Int(inputFormat.sampleRate)) Hz \(inputFormat.channelCount) ch, output 16000 Hz mono, capacity \(sink.capacityFrames) frames"
        )
        return format
    }

    func snapshot() -> CaptureSnapshot {
        guard let sink = lock.withLock({ session?.sink }) else { return CaptureSnapshot() }
        return sink.snapshot()
    }

    func stop(reason: UtteranceEndReason) async -> CapturedUtterance? {
        guard let current = lock.withLock({ session }) else { return nil }
        let sink = current.sink

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // The tap is gone, so draining the resampler here is race-free and keeps
        // the trailing milliseconds of speech that are still inside the converter.
        if let tail = try? current.converter.drain(), !tail.isEmpty {
            sink.ingest(tail)
        }

        let utterance = sink.finish(reason: reason)
        teardown()

        Log.audio.info(
            "Capture finished: \(String(format: "%.2f", utterance.duration)) s, \(utterance.frameCount) frames, dropped \(utterance.droppedFrameCount), reason \(reason.rawValue, privacy: .public)"
        )
        return utterance
    }

    // MARK: - Real-time path

    private func handleTap(buffer: AVAudioPCMBuffer, sink: PCMCaptureSink, converter: AudioFormatConverter) {
        do {
            let frames = try converter.convert(buffer)
            guard !frames.isEmpty else { return }
            sink.ingest(frames)
        } catch {
            // Conversion failures are surfaced through the interruption handler;
            // the audio thread itself only reads the stored closure.
            let handler = lock.withLock { interruptionHandler }
            let captureError = (error as? AudioCaptureError) ?? .conversionFailed("\(error)")
            handler?(captureError)
        }
    }

    // MARK: - Device changes

    private func observeConfigurationChanges() {
        guard lock.withLock({ configurationObserver == nil }) else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let handler = self.lock.withLock { self.interruptionHandler }
            guard handler != nil else { return }
            Log.audio.notice("Audio engine configuration changed during capture")
            handler?(.inputDeviceChanged)
        }
        lock.withLock { configurationObserver = observer }
    }

    private func teardown() {
        lock.withLock {
            session = nil
            interruptionHandler = nil
        }
    }
}
