import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// `AVAudioEngine`-backed capture.
///
/// The input tap converts device buffers to mono Float32 16 kHz and appends them
/// to a bounded in-memory sink. The callback performs no allocation beyond the
/// converter's reused output buffer, never logs samples, and never writes to disk.
/// Engine lifecycle is guarded by an unfair lock because `AVAudioEngine` is not
/// `Sendable` and start/stop can arrive from different tasks.
final class AVAudioEngineCaptureService: AudioCaptureService, @unchecked Sendable {
    enum ConfigurationChangeAction: Equatable {
        case keepRecording
        case resumeEngine
        case interrupt
    }

    static func actionAfterConfigurationChange(
        engineIsRunning: Bool,
        expectedInputID: AudioDeviceID,
        resolvedInputID: AudioDeviceID?,
        inputFormatMatches: Bool
    ) -> ConfigurationChangeAction {
        if engineIsRunning { return .keepRecording }
        guard resolvedInputID == expectedInputID, inputFormatMatches else { return .interrupt }
        return .resumeEngine
    }

    private struct Session {
        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        let sink: PCMCaptureSink
        let converter: AudioFormatConverter
        let format: CaptureFormatDescription
        let inputSelection: AudioInputSelection
        let inputDeviceID: AudioDeviceID
    }

    private let lock = UnfairLock()
    private let lifecycleLock = UnfairLock()
    private var session: Session?
    private var configurationObserver: NSObjectProtocol?
    private var interruptionHandler: (@Sendable (AudioCaptureError) -> Void)?
    private var recoveringEngine: AVAudioEngine?
    private var recoveryAttempts = 0
    private var lastRecoveryUptime: TimeInterval = 0

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
        // A fresh graph lets each utterance bind its chosen input before the
        // I/O unit is initialized, including after an AirPods route change.
        if lock.withLock({ session != nil }) {
            _ = await stop(reason: .interrupted)
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let resolution = SystemAudioInput.resolve(configuration.inputSelection) else {
            throw AudioCaptureError.noInputDevice
        }
        if configuration.inputSelection != .systemDefault {
            guard let audioUnit = inputNode.audioUnit else {
                throw AudioCaptureError.inputDeviceSelectionFailed("input audio unit is unavailable")
            }
            var deviceID = resolution.device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioCaptureError.inputDeviceSelectionFailed("Core Audio status \(status)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

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
            inputDeviceName: resolution.device.name,
            inputSampleRate: inputFormat.sampleRate,
            inputChannelCount: Int(inputFormat.channelCount),
            outputSampleRate: AudioTargetFormat.sampleRate,
            outputChannelCount: AudioTargetFormat.channelCount,
            bufferCapacityFrames: sink.capacityFrames
        )

        lock.withLock {
            session = Session(
                engine: engine,
                inputNode: inputNode,
                sink: sink,
                converter: converter,
                format: format,
                inputSelection: configuration.inputSelection,
                inputDeviceID: resolution.device.id
            )
            interruptionHandler = onInterruption
            recoveringEngine = nil
            recoveryAttempts = 0
            lastRecoveryUptime = 0
        }

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
            engine.stop()
            teardown()
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        // Selecting a per-app input can itself queue a configuration notice.
        // Observe only after the graph is running, then recover if a later
        // hardware change actually stops it.
        observeConfigurationChanges(engine: engine)
        if !engine.isRunning {
            scheduleRecovery(for: engine)
        }

        Log.audio.info(
            "Capture started: input \(Int(inputFormat.sampleRate)) Hz \(inputFormat.channelCount) ch, output 16000 Hz mono, capacity \(sink.capacityFrames) frames"
        )
        if resolution.usedFallback {
            Log.audio.notice("Preferred microphone unavailable; capture uses another local input")
        }
        return format
    }

    func snapshot() -> CaptureSnapshot {
        guard let sink = lock.withLock({ session?.sink }) else { return CaptureSnapshot() }
        return sink.snapshot()
    }

    func stop(reason: UtteranceEndReason) async -> CapturedUtterance? {
        guard let current = lock.withLock({ () -> Session? in
            interruptionHandler = nil
            return session
        }) else { return nil }
        let sink = current.sink

        lifecycleLock.withLock {
            current.inputNode.removeTap(onBus: 0)
            current.engine.stop()
        }

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

    private func observeConfigurationChanges(engine: AVAudioEngine) {
        guard lock.withLock({ configurationObserver == nil }) else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let engine else { return }
            guard let self else { return }
            self.scheduleRecovery(for: engine)
        }
        lock.withLock { configurationObserver = observer }
    }

    private func scheduleRecovery(for engine: AVAudioEngine) {
        let shouldRecover = lock.withLock { () -> Bool in
            guard session?.engine === engine, interruptionHandler != nil, recoveringEngine == nil else { return false }
            recoveringEngine = engine
            return true
        }
        guard shouldRecover else { return }

        // Apple's configuration callback runs on an internal audio queue. Do
        // not stop, restart, or deallocate the engine from that callback.
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.recover(engine)
        }
    }

    private func recover(_ engine: AVAudioEngine) {
        let failure: AudioCaptureError? = lifecycleLock.withLock {
            guard let current = lock.withLock({ session?.engine === engine && interruptionHandler != nil ? session : nil }) else {
                return nil
            }
            // A tap and converter are valid only for the input format they
            // were created with. A changed format needs a fresh utterance.
            let resolved = SystemAudioInput.resolve(current.inputSelection)
            let inputFormat = current.inputNode.outputFormat(forBus: 0)
            let action = Self.actionAfterConfigurationChange(
                engineIsRunning: engine.isRunning,
                expectedInputID: current.inputDeviceID,
                resolvedInputID: resolved?.device.id,
                inputFormatMatches: inputFormat.sampleRate == current.format.inputSampleRate
                    && Int(inputFormat.channelCount) == current.format.inputChannelCount
            )
            switch action {
            case .keepRecording:
                return nil
            case .interrupt:
                return resolved == nil ? .noInputDevice : .inputDeviceChanged
            case .resumeEngine:
                break
            }

            let attempt = lock.withLock { () -> Int in
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastRecoveryUptime > 2 { recoveryAttempts = 0 }
                lastRecoveryUptime = now
                recoveryAttempts += 1
                return recoveryAttempts
            }
            guard attempt <= 4 else {
                return .engineStartFailed("the audio engine stopped repeatedly")
            }

            do {
                try engine.start()
                guard engine.isRunning else {
                    return .engineStartFailed("the audio engine did not resume")
                }
                Log.audio.notice("Audio engine resumed with the same microphone")
                return nil
            } catch {
                return .engineStartFailed(error.localizedDescription)
            }
        }

        let handler = lock.withLock { () -> (@Sendable (AudioCaptureError) -> Void)? in
            if recoveringEngine === engine { recoveringEngine = nil }
            return session?.engine === engine ? interruptionHandler : nil
        }
        if let failure {
            handler?(failure)
        }
    }

    private func teardown() {
        let observer = lock.withLock { () -> NSObjectProtocol? in
            session = nil
            interruptionHandler = nil
            recoveringEngine = nil
            recoveryAttempts = 0
            lastRecoveryUptime = 0
            let observer = configurationObserver
            configurationObserver = nil
            return observer
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
