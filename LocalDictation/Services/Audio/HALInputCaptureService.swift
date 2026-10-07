import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Capture that opens the chosen microphone directly, input only, and follows it
/// when the route changes.
///
/// `AVAudioEngine` records through a private `CADefaultDeviceAggregate` whose IO
/// work loop is the default *output* device, so connecting headphones rebuilt the
/// input path and stopped the engine mid-sentence. An input-only AUHAL unit bound
/// to an explicit device has no such coupling.
///
/// The recording is split in two. The **utterance** owns the sink and the voice
/// activity detector and lasts for the whole recording. An **input segment** owns
/// one audio unit bound to one device in one format, and is replaced whenever the
/// route changes: the old segment is drained into the same sink, so the sentence
/// continues across the change and the user sees nothing.
///
/// The client format is always mono at the device rate, with an explicit channel
/// map taking device channel 0. That is what makes a microphone reporting a raw
/// 3-channel array during someone else's call record normally.
///
/// Segment lifecycle runs entirely on one private serial queue, shared with the
/// route monitor. `@unchecked Sendable` because the audio unit and its buffers
/// are not `Sendable`; the contract is that only that queue touches them.
final class HALInputCaptureService: AudioCaptureService, @unchecked Sendable {
    /// One binding to one device.
    fileprivate final class InputSegment {
        let unit: AudioUnit
        let deviceID: AudioDeviceID
        let deviceName: String
        let binding: InputBinding
        let converter: AudioFormatConverter
        let sink: PCMCaptureSink
        /// Rendered into by the audio callback and handed to the converter. Sized
        /// once from the unit's maximum slice, so the callback never allocates.
        let renderBuffer: AVAudioPCMBuffer
        /// Written by the audio callback, read by the watchdog. An aligned 64-bit
        /// store, and a heartbeat rather than a value anything computes with, so
        /// it needs no lock on the real-time thread.
        var lastCallbackUptime: TimeInterval
        /// Set by the audio callback when `AudioUnitRender` or conversion fails.
        var failure: OSStatus = noErr
        /// Frames of bit-exact zeros since this segment opened, and whether it
        /// has ever delivered anything else. Written by the audio callback and
        /// read by the watchdog under the same contract as `lastCallbackUptime`:
        /// aligned stores of values nothing computes with, so the real-time
        /// thread takes no lock for them.
        var silentFrames = 0
        var sawSignal = false
        /// Whether a run of zeros from this device is worth reporting. True only
        /// for Bluetooth: there it means a headset that answered us while its
        /// microphone stayed with another host. On a local microphone exact zeros
        /// mean the input is muted, and switching away from a microphone someone
        /// muted on purpose is the last thing capture should do.
        let watchesDigitalSilence: Bool

        /// How long this device has been handing us nothing, or `nil` when there
        /// is nothing to suspect.
        var digitalSilenceSeconds: Double? {
            guard watchesDigitalSilence, !sawSignal, binding.sampleRate > 0 else { return nil }
            return Double(silentFrames) / binding.sampleRate
        }

        init(
            unit: AudioUnit,
            deviceID: AudioDeviceID,
            deviceName: String,
            binding: InputBinding,
            converter: AudioFormatConverter,
            sink: PCMCaptureSink,
            renderBuffer: AVAudioPCMBuffer,
            watchesDigitalSilence: Bool,
            startedAt: TimeInterval
        ) {
            self.unit = unit
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.binding = binding
            self.converter = converter
            self.sink = sink
            self.renderBuffer = renderBuffer
            self.watchesDigitalSilence = watchesDigitalSilence
            self.lastCallbackUptime = startedAt
        }
    }

    /// One recording. Lives on the service's queue.
    private final class Session {
        var segment: InputSegment?
        /// The last binding that was live. Kept on the session rather than read
        /// from the segment, because a rebind that failed leaves no segment and
        /// the next decision still needs to know where we were.
        var binding: InputBinding
        let sink: PCMCaptureSink
        let selection: AudioInputSelection
        let format: CaptureFormatDescription
        let onInterruption: @Sendable (AudioCaptureError) -> Void
        var budget = RebindBudget()
        var rebindCount = 0
        var isFinished = false

        init(
            segment: InputSegment,
            sink: PCMCaptureSink,
            selection: AudioInputSelection,
            format: CaptureFormatDescription,
            onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
        ) {
            self.segment = segment
            self.binding = segment.binding
            self.sink = sink
            self.selection = selection
            self.format = format
            self.onInterruption = onInterruption
        }
    }

    private let hardware: any AudioHardware
    private let queue: DispatchQueue
    private let monitor: InputRouteMonitor
    /// How long to wait before looking again when nothing is resolvable yet.
    private let retryDelay: TimeInterval

    /// Touched only on `queue`.
    private var session: Session?
    /// A headset that delivered only zeros, so the next press does not lose its
    /// first word to it again. Touched only on `queue`.
    private var silentInputs = SilentInputMemory()

    /// Read from the main actor by `snapshot`, so it may not go through `queue`.
    private let stateLock = UnfairLock()
    private var liveSink: PCMCaptureSink?

    init(
        hardware: any AudioHardware = SystemAudioHardware(),
        quietPeriod: TimeInterval = 0.15,
        retryDelay: TimeInterval = 0.15
    ) {
        let queue = DispatchQueue(label: "com.witnessmac.Witness.capture-route", qos: .userInitiated)
        self.hardware = hardware
        self.queue = queue
        self.retryDelay = retryDelay
        self.monitor = InputRouteMonitor(hardware: hardware, queue: queue, quietPeriod: quietPeriod)
    }

    // MARK: - AudioCaptureService

    func start(
        configuration: AudioCaptureConfiguration,
        onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
    ) async throws -> CaptureFormatDescription {
        if stateLock.withLock({ liveSink != nil }) {
            _ = await stop(reason: .interrupted)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try openSession(configuration, onInterruption))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func snapshot() -> CaptureSnapshot {
        guard let sink = stateLock.withLock({ liveSink }) else { return CaptureSnapshot() }
        return sink.snapshot()
    }

    func stop(reason: UtteranceEndReason) async -> CapturedUtterance? {
        monitor.stop()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: closeSession(reason: reason))
            }
        }
    }

    // MARK: - Session lifecycle, on `queue`

    private func openSession(
        _ configuration: AudioCaptureConfiguration,
        _ onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
    ) throws -> CaptureFormatDescription {
        let devices = hardware.availableInputDevices()
        let defaultID = hardware.defaultInputDeviceID()
        guard let start = SystemAudioInput.resolveStart(
            configuration.inputSelection,
            among: devices,
            defaultID: defaultID,
            avoiding: silentInputs.deviceToAvoid(among: devices, defaultInputID: defaultID, at: Date())
        ) else {
            throw AudioCaptureError.noInputDevice
        }
        let (resolution, skipped) = start

        let detector = EnergyVoiceActivityDetector(
            configuration: configuration.voiceActivity,
            sampleRate: AudioTargetFormat.sampleRate
        )
        let sink = PCMCaptureSink(
            capacityFrames: configuration.bufferCapacityFrames,
            sampleRate: AudioTargetFormat.sampleRate,
            detector: detector
        )

        let segment = try makeSegment(device: resolution.device, sink: sink)
        let status = AudioOutputUnitStart(segment.unit)
        guard status == noErr else {
            Self.dispose(segment)
            throw AudioCaptureError.engineStartFailed("Core Audio status \(status)")
        }

        let format = CaptureFormatDescription(
            inputDeviceName: segment.deviceName,
            inputSampleRate: segment.binding.sampleRate,
            inputChannelCount: segment.binding.channelCount,
            outputSampleRate: AudioTargetFormat.sampleRate,
            outputChannelCount: AudioTargetFormat.channelCount,
            bufferCapacityFrames: sink.capacityFrames
        )
        let session = Session(
            segment: segment,
            sink: sink,
            selection: configuration.inputSelection,
            format: format,
            onInterruption: onInterruption
        )
        self.session = session
        stateLock.withLock { liveSink = sink }

        monitor.start(
            device: segment.deviceID,
            // Read on the monitor's queue, which is this service's queue, so
            // reaching the live segment through `self` is safe and always sees
            // the current one rather than the segment start began with.
            progress: { [weak self] in
                guard let segment = self?.session?.segment else {
                    return InputProgress(lastCallbackUptime: ProcessInfo.processInfo.systemUptime, digitalSilenceSeconds: nil)
                }
                return InputProgress(
                    lastCallbackUptime: segment.lastCallbackUptime,
                    digitalSilenceSeconds: segment.digitalSilenceSeconds
                )
            },
            onEvent: { [weak self] event in self?.handle(event) }
        )

        Log.audio.info(
            "Capture started: \(segment.deviceName, privacy: .public) (\(Self.describe(segment.binding.mode), privacy: .public)), device \(Int(segment.binding.sampleRate)) Hz \(segment.binding.channelCount) ch, client 16000 Hz mono from channel 0, capacity \(sink.capacityFrames) frames"
        )
        if let skipped {
            Log.audio.notice(
                "Capture skipped \(skipped.name, privacy: .public): it delivered only silence on a recent recording"
            )
        } else if resolution.usedFallback {
            Log.audio.notice("Preferred microphone unavailable; capture uses another local input")
        }
        return format
    }

    private func closeSession(reason: UtteranceEndReason) -> CapturedUtterance? {
        guard let current = session else { return nil }
        session = nil
        stateLock.withLock { liveSink = nil }
        current.isFinished = true

        if let segment = current.segment {
            AudioOutputUnitStop(segment.unit)
            // The callback has stopped, so draining the resampler here is
            // race-free and keeps the trailing milliseconds still inside it.
            drain(segment, into: current.sink)
            Self.dispose(segment)
            current.segment = nil
            if segment.failure != noErr {
                Log.audio.notice("Input callback reported Core Audio status \(segment.failure) during this utterance")
            }
        }

        let utterance = current.sink.finish(reason: reason, rebindCount: current.rebindCount)
        Log.audio.info(
            "Capture finished: \(String(format: "%.2f", utterance.duration), privacy: .public) s, \(utterance.frameCount) frames, dropped \(utterance.droppedFrameCount), rebinds \(current.rebindCount), reason \(reason.rawValue, privacy: .public)"
        )
        return utterance
    }

    // MARK: - Route changes, on `queue`

    private func handle(_ event: InputRouteEvent) {
        guard let session, !session.isFinished else { return }
        let binding = session.binding

        let snapshot = makeSnapshot(binding: binding)
        let action = InputRoutePolicy.action(
            for: event,
            selection: session.selection,
            binding: binding,
            snapshot: snapshot
        )

        // Leaving a silent headset for another microphone is a verdict worth
        // keeping: without it the next press opens the same headset and loses
        // its first word the same way.
        if event == .boundDeviceDeliveredSilence,
           case let .rebind(elsewhere) = action, elsewhere != binding.deviceID,
           let silent = snapshot.devices.first(where: { $0.id == binding.deviceID }) {
            silentInputs.remember(silent, defaultInputID: snapshot.defaultInputID, at: Date())
        }

        if event == .boundDeviceDeliveredSilence, action == .keep {
            Log.audio.notice(
                "Input delivered only silence and there is no other microphone to move to; the recording continues on \(session.segment?.deviceName ?? "the same device", privacy: .public)"
            )
        }

        switch action {
        case .keep:
            // Unless a previous attempt left nothing running. Keeping a
            // recording with no microphone open would record silence for the
            // rest of the sentence and say nothing about it.
            if session.segment == nil {
                rebind(session, to: binding.deviceID, because: event)
            }
            return
        case let .rebind(device):
            rebind(session, to: device, because: event)
        case let .escalate(device):
            rebind(session, to: device, because: event, mode: .voiceProcessing)
        case let .interrupt(error):
            // A microphone that vanished often comes back within a moment: an
            // aggregate being rebuilt, a dock waking up. Ending the sentence is
            // the last resort, not the first answer.
            if error == .noInputDevice,
               session.budget.toleratesMissingInput(at: ProcessInfo.processInfo.systemUptime) {
                retry(event, on: session)
                return
            }
            finish(session, with: error)
        }
    }

    private func retry(_ event: InputRouteEvent, on session: Session) {
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak session] in
            guard let self, let session, !session.isFinished, self.session === session else { return }
            self.handle(event)
        }
    }

    private func rebind(
        _ session: Session,
        to device: AudioDeviceID,
        because event: InputRouteEvent,
        mode: InputCaptureMode = .direct
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard session.budget.allowsAttempt(at: now) else {
            finish(session, with: .engineStartFailed("the microphone could not be reopened"))
            return
        }

        guard let replacement = hardware.availableInputDevices().first(where: { $0.id == device }) else {
            retry(event, on: session)
            return
        }

        let from = session.segment?.deviceName
        // Measured from the last frame that actually arrived, not from the
        // moment we decided to act. The device stops delivering as soon as
        // whoever is reconfiguring it takes over, which is well before the
        // notification reaches us and before the debounce elapses. Timing our
        // own teardown instead reported a quarter of the real silence.
        let lastFrameAt = session.segment?.lastCallbackUptime ?? ProcessInfo.processInfo.systemUptime
        if let old = session.segment {
            AudioOutputUnitStop(old.unit)
            drain(old, into: session.sink)
            Self.dispose(old)
            session.segment = nil
        }

        do {
            let segment = try makeSegment(device: replacement, sink: session.sink, mode: mode)

            let status = AudioOutputUnitStart(segment.unit)
            guard status == noErr else {
                Self.dispose(segment)
                throw AudioCaptureError.engineStartFailed("Core Audio status \(status)")
            }
            session.segment = segment
            session.binding = segment.binding
            session.rebindCount += 1
            session.budget.recordSuccess()
            monitor.rebound(to: segment.deviceID)

            let gap = (ProcessInfo.processInfo.systemUptime - lastFrameAt) * 1000
            Log.audio.notice(
                "Input rebound (\(String(describing: event), privacy: .public)): \(from ?? "none", privacy: .public) -> \(segment.deviceName, privacy: .public) (\(Self.describe(segment.binding.mode), privacy: .public)), \(Int(segment.binding.sampleRate)) Hz \(segment.binding.channelCount) ch, gap \(String(format: "%.0f", gap), privacy: .public) ms"
            )
        } catch {
            // No segment is running now. The retry re-reads the hardware, so a
            // device that is mid-reconfiguration gets another chance.
            retry(event, on: session)
        }
    }

    private func finish(_ session: Session, with error: AudioCaptureError) {
        guard !session.isFinished else { return }
        session.isFinished = true
        monitor.stop()
        Log.audio.notice("Capture interrupted: \(error.message, privacy: .public)")
        session.onInterruption(error)
    }

    private func makeSnapshot(binding: InputBinding) -> InputRouteSnapshot {
        InputRouteSnapshot(
            devices: hardware.availableInputDevices(),
            defaultInputID: hardware.defaultInputDeviceID(),
            boundIsAlive: hardware.isAlive(binding.deviceID),
            boundSampleRate: hardware.nominalSampleRate(of: binding.deviceID),
            boundChannelCount: hardware.inputChannelCount(of: binding.deviceID)
        )
    }

    private func drain(_ segment: InputSegment, into sink: PCMCaptureSink) {
        if let tail = try? segment.converter.drain(), !tail.isEmpty {
            sink.ingest(tail)
        }
    }

    // MARK: - Building a segment

    /// Opens the device, directly unless the route policy has asked for the
    /// stronger claim.
    ///
    /// Voice processing is pickier than the plain unit about which formats it
    /// will accept, and which combination works depends on the device, so it is
    /// asked twice with decreasing demands. If it will not open at all, the
    /// direct path still records: failing the press would be worse than
    /// recording without the claim.
    private func makeSegment(
        device: SystemAudioInput.Device,
        sink: PCMCaptureSink,
        mode: InputCaptureMode = .direct
    ) throws -> InputSegment {
        guard mode == .voiceProcessing else {
            return try openSegment(device: device, sink: sink, mode: .direct, setsPlaybackFormat: false)
        }

        var failures: [String] = []
        for setsPlaybackFormat in [true, false] {
            do {
                return try openSegment(
                    device: device, sink: sink, mode: .voiceProcessing, setsPlaybackFormat: setsPlaybackFormat
                )
            } catch {
                failures.append((error as? AudioCaptureError)?.message ?? "\(error)")
            }
        }
        Log.audio.notice(
            "Voice processing would not open \(device.name, privacy: .public) (\(failures.joined(separator: "; "), privacy: .public)); capture falls back to the direct input path"
        )
        return try openSegment(device: device, sink: sink, mode: .direct, setsPlaybackFormat: false)
    }

    private func openSegment(
        device: SystemAudioInput.Device,
        sink: PCMCaptureSink,
        mode: InputCaptureMode,
        setsPlaybackFormat: Bool
    ) throws -> InputSegment {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: mode == .voiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.engineStartFailed("the HAL output audio unit is unavailable")
        }

        var unitOrNil: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unitOrNil), "instantiating the audio unit")
        guard let unit = unitOrNil else {
            throw AudioCaptureError.engineStartFailed("the audio unit could not be instantiated")
        }

        do {
            return try configure(
                unit: unit, device: device, sink: sink, mode: mode, setsPlaybackFormat: setsPlaybackFormat
            )
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    static func describe(_ mode: InputCaptureMode) -> String {
        switch mode {
        case .direct: "direct"
        case .voiceProcessing: "voice processing"
        }
    }

    private func configure(
        unit: AudioUnit,
        device: SystemAudioInput.Device,
        sink: PCMCaptureSink,
        mode: InputCaptureMode,
        setsPlaybackFormat: Bool
    ) throws -> InputSegment {
        // Input on element 1. Output stays off on element 0 for the direct path:
        // without turning it off the unit would pull the default output device
        // into our IO cycle, which is exactly the coupling this service exists to
        // remove. Voice processing needs its output half, and that is the point
        // of it here rather than a side effect: owning both halves of the device
        // is what a call owns, and what a shared headset answers to.
        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                Self.inputElement, &enable, UInt32(MemoryLayout<UInt32>.size)
            ),
            "enabling input"
        )
        var playback: UInt32 = mode == .voiceProcessing ? 1 : 0
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                Self.outputElement, &playback, UInt32(MemoryLayout<UInt32>.size)
            ),
            mode == .voiceProcessing ? "enabling the output half" : "disabling output"
        )

        // Always bind the device explicitly, `systemDefault` included. Leaving it
        // unset is what makes Core Audio build the aggregate clocked by the
        // speakers.
        var deviceID = device.id
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                Self.outputElement, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "selecting the input device"
        )

        var hardwareFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                Self.inputElement, &hardwareFormat, &formatSize
            ),
            "reading the hardware format"
        )
        let hardwareSampleRate = hardwareFormat.mSampleRate > 0
            ? hardwareFormat.mSampleRate
            : (hardware.nominalSampleRate(of: device.id) ?? 0)
        guard hardwareSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0 else {
            throw AudioCaptureError.unsupportedInputFormat(
                "\(hardwareFormat.mSampleRate) Hz, \(hardwareFormat.mChannelsPerFrame) ch"
            )
        }

        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedInputFormat("mono at \(hardwareSampleRate) Hz")
        }
        var clientDescription = clientFormat.streamDescription.pointee
        try check(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                Self.inputElement, &clientDescription,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "setting the client format"
        )

        if mode == .voiceProcessing {
            // The output half is fed silence, so it needs a format too. Some
            // devices refuse ours there and initialize only with their own,
            // which is what `setsPlaybackFormat` exists for.
            if setsPlaybackFormat {
                try check(
                    AudioUnitSetProperty(
                        unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                        Self.outputElement, &clientDescription,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    ),
                    "setting the playback format"
                )
            }
        } else {
            // One client channel, fed from device channel 0. On a raw microphone
            // array channel 0 is the one that carries speech; the others are quiet
            // array channels that would only add noise if they were mixed in.
            // Voice processing does its own channel handling and rejects a map.
            var channelMap: Int32 = 0
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output,
                    Self.inputElement, &channelMap, UInt32(MemoryLayout<Int32>.size)
                ),
                "mapping device channel 0"
            )
        }

        var maximumFrames: UInt32 = 0
        var maximumFramesSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                Self.outputElement, &maximumFrames, &maximumFramesSize
            ),
            "reading the maximum slice size"
        )
        // Headroom for a driver that hands us a longer slice than it advertised.
        let capacity = AVAudioFrameCount(max(maximumFrames, 4096)) * 2
        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.converterUnavailable("render buffer could not be allocated")
        }

        let converter = try AudioFormatConverter(
            inputFormat: clientFormat,
            maximumInputFrames: capacity
        )

        let segment = InputSegment(
            unit: unit,
            deviceID: device.id,
            deviceName: device.name,
            binding: InputBinding(
                deviceID: device.id,
                sampleRate: hardwareSampleRate,
                channelCount: Int(hardwareFormat.mChannelsPerFrame),
                mode: mode
            ),
            converter: converter,
            sink: sink,
            renderBuffer: renderBuffer,
            watchesDigitalSilence: device.isBluetooth,
            startedAt: ProcessInfo.processInfo.systemUptime
        )

        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(segment).toOpaque()
        )
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                Self.outputElement, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "installing the input callback"
        )

        if mode == .voiceProcessing {
            var playbackCallback = AURenderCallbackStruct(inputProc: halSilenceCallback, inputProcRefCon: nil)
            try check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                    Self.outputElement, &playbackCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "installing the playback callback"
            )
        }

        try check(AudioUnitInitialize(unit), "initializing the audio unit")
        return segment
    }

    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw AudioCaptureError.inputDeviceSelectionFailed("\(what) failed with Core Audio status \(status)")
    }

    private static func dispose(_ segment: InputSegment) {
        AudioUnitUninitialize(segment.unit)
        AudioComponentInstanceDispose(segment.unit)
    }

    // MARK: - Real-time path

    /// Called from the HAL IO thread through the C callback below. Renders one
    /// slice into the preallocated mono buffer, converts it, and appends it to
    /// the sink. No allocation, no logging, no main actor, and no lock beyond
    /// the sink's own.
    fileprivate static func render(
        segment: InputSegment,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        segment.lastCallbackUptime = ProcessInfo.processInfo.systemUptime
        guard frameCount > 0 else { return noErr }
        let buffer = segment.renderBuffer
        guard frameCount <= buffer.frameCapacity else {
            segment.failure = kAudio_ParamError
            return kAudio_ParamError
        }

        // `AudioUnitRender` overwrites `mDataByteSize`, so it is restored to the
        // full slice length before every call.
        let list = buffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frameCount * 4

        let status = AudioUnitRender(segment.unit, flags, timestamp, inputElement, frameCount, list)
        guard status == noErr else {
            segment.failure = status
            return status
        }

        if segment.watchesDigitalSilence, !segment.sawSignal {
            // A headset that answers the Mac while its microphone stays with
            // another host delivers bit-exact zeros, on time, for as long as the
            // recording lasts. Nothing else in the route says so, so the only
            // place to notice it is here. The scan stops at the first sample that
            // is not zero, and once this segment has heard anything it is never
            // run again.
            var hasSignal = false
            if let samples = buffer.floatChannelData?[0] {
                var index = 0
                while index < Int(frameCount) {
                    if samples[index] != 0 {
                        hasSignal = true
                        break
                    }
                    index += 1
                }
            }
            if hasSignal {
                segment.sawSignal = true
                segment.silentFrames = 0
            } else {
                segment.silentFrames += Int(frameCount)
            }
        }

        buffer.frameLength = frameCount
        do {
            let frames = try segment.converter.convert(buffer)
            guard !frames.isEmpty else { return noErr }
            segment.sink.ingest(frames)
        } catch {
            segment.failure = kAudioUnitErr_InvalidPropertyValue
        }
        return noErr
    }
}

/// Feeds the playback half of a voice processing unit silence.
///
/// The claim is the point, not the sound: voice processing has to own both halves
/// of the device, and capture has nothing to play.
private func halSilenceCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frameCount: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    for buffer in buffers {
        guard let bytes = buffer.mData else { continue }
        memset(bytes, 0, Int(buffer.mDataByteSize))
    }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

/// The C entry point the HAL calls on its IO thread. It cannot capture context,
/// so the segment travels through `inputProcRefCon` unretained; the service
/// stops and uninitializes the unit before the segment is released.
private func halInputCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frameCount: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let segment = Unmanaged<HALInputCaptureService.InputSegment>.fromOpaque(refCon).takeUnretainedValue()
    return HALInputCaptureService.render(
        segment: segment,
        flags: flags,
        timestamp: timestamp,
        frameCount: frameCount
    )
}
