import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Capture that opens the chosen microphone directly, input only.
///
/// `AVAudioEngine` records through a private `CADefaultDeviceAggregate` whose IO
/// work loop is the default *output* device, so connecting headphones rebuilds
/// the input path and stops the engine mid-sentence. An input-only AUHAL unit
/// bound to an explicit device has no such coupling: output devices come and go
/// without capture noticing.
///
/// The client format is always mono at the device rate, with an explicit channel
/// map taking device channel 0. That is what makes a microphone reporting a raw
/// 3-channel array during someone else's call record normally.
///
/// `@unchecked Sendable` for the same reason as the engine service: the audio
/// unit and its buffers are not `Sendable`, and the contract is that one capture
/// session owns them, with start and stop serialized by a lock.
final class HALInputCaptureService: AudioCaptureService, @unchecked Sendable {
    /// One binding to one device. The utterance outlives it; slice 3 replaces a
    /// segment mid-recording when the route changes.
    fileprivate final class InputSegment {
        let unit: AudioUnit
        let deviceID: AudioDeviceID
        let deviceName: String
        let hardwareSampleRate: Double
        let hardwareChannelCount: Int
        let converter: AudioFormatConverter
        let sink: PCMCaptureSink
        /// Rendered into by the audio callback and handed to the converter. Sized
        /// once from the unit's maximum slice, so the callback never allocates.
        let renderBuffer: AVAudioPCMBuffer
        /// Set by the audio callback when `AudioUnitRender` or conversion fails.
        /// Read off the audio thread; the callback itself only writes it.
        var failure: OSStatus = noErr

        init(
            unit: AudioUnit,
            deviceID: AudioDeviceID,
            deviceName: String,
            hardwareSampleRate: Double,
            hardwareChannelCount: Int,
            converter: AudioFormatConverter,
            sink: PCMCaptureSink,
            renderBuffer: AVAudioPCMBuffer
        ) {
            self.unit = unit
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.hardwareSampleRate = hardwareSampleRate
            self.hardwareChannelCount = hardwareChannelCount
            self.converter = converter
            self.sink = sink
            self.renderBuffer = renderBuffer
        }
    }

    private struct Session {
        let segment: InputSegment
        let sink: PCMCaptureSink
        let format: CaptureFormatDescription
        let inputSelection: AudioInputSelection
    }

    private let hardware: any AudioHardware
    private let lock = UnfairLock()
    private var session: Session?
    private var interruptionHandler: (@Sendable (AudioCaptureError) -> Void)?

    init(hardware: any AudioHardware = SystemAudioHardware()) {
        self.hardware = hardware
    }

    deinit {
        if let segment = session?.segment {
            AudioOutputUnitStop(segment.unit)
            Self.dispose(segment)
        }
    }

    // MARK: - AudioCaptureService

    func start(
        configuration: AudioCaptureConfiguration,
        onInterruption: @escaping @Sendable (AudioCaptureError) -> Void
    ) async throws -> CaptureFormatDescription {
        if lock.withLock({ session != nil }) {
            _ = await stop(reason: .interrupted)
        }

        guard let resolution = SystemAudioInput.resolve(
            configuration.inputSelection,
            among: hardware.availableInputDevices(),
            defaultID: hardware.defaultInputDeviceID()
        ) else {
            throw AudioCaptureError.noInputDevice
        }

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
        let format = CaptureFormatDescription(
            inputDeviceName: segment.deviceName,
            inputSampleRate: segment.hardwareSampleRate,
            inputChannelCount: segment.hardwareChannelCount,
            outputSampleRate: AudioTargetFormat.sampleRate,
            outputChannelCount: AudioTargetFormat.channelCount,
            bufferCapacityFrames: sink.capacityFrames
        )

        lock.withLock {
            session = Session(
                segment: segment,
                sink: sink,
                format: format,
                inputSelection: configuration.inputSelection
            )
            interruptionHandler = onInterruption
        }

        let status = AudioOutputUnitStart(segment.unit)
        guard status == noErr else {
            Self.dispose(segment)
            lock.withLock {
                session = nil
                interruptionHandler = nil
            }
            throw AudioCaptureError.engineStartFailed("Core Audio status \(status)")
        }

        Log.audio.info(
            "Capture started: \(segment.deviceName, privacy: .public), device \(Int(segment.hardwareSampleRate)) Hz \(segment.hardwareChannelCount) ch, client 16000 Hz mono from channel 0, capacity \(sink.capacityFrames) frames"
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
            let running = session
            session = nil
            interruptionHandler = nil
            return running
        }) else { return nil }

        let segment = current.segment
        AudioOutputUnitStop(segment.unit)

        // The callback has stopped, so draining the resampler here is race-free
        // and keeps the trailing milliseconds still inside the converter.
        if let tail = try? segment.converter.drain(), !tail.isEmpty {
            current.sink.ingest(tail)
        }
        Self.dispose(segment)

        if segment.failure != noErr {
            Log.audio.notice("Input callback reported Core Audio status \(segment.failure) during this utterance")
        }

        let utterance = current.sink.finish(reason: reason)
        Log.audio.info(
            "Capture finished: \(String(format: "%.2f", utterance.duration)) s, \(utterance.frameCount) frames, dropped \(utterance.droppedFrameCount), reason \(reason.rawValue, privacy: .public)"
        )
        return utterance
    }

    // MARK: - Building a segment

    private func makeSegment(device: SystemAudioInput.Device, sink: PCMCaptureSink) throws -> InputSegment {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
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

        // Anything after this point that throws must not leak the unit.
        do {
            return try configure(unit: unit, device: device, sink: sink)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func configure(
        unit: AudioUnit,
        device: SystemAudioInput.Device,
        sink: PCMCaptureSink
    ) throws -> InputSegment {
        // Input on element 1, output off on element 0. Without turning output
        // off the unit would pull the default output device into our IO cycle,
        // which is exactly the coupling this service exists to remove.
        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                Self.inputElement, &enable, UInt32(MemoryLayout<UInt32>.size)
            ),
            "enabling input"
        )
        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                Self.outputElement, &disable, UInt32(MemoryLayout<UInt32>.size)
            ),
            "disabling output"
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

        // One client channel, fed from device channel 0. On a raw microphone
        // array channel 0 is the one that carries speech; the others are quiet
        // array channels that would only add noise if they were mixed in.
        var channelMap: Int32 = 0
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output,
                Self.inputElement, &channelMap, UInt32(MemoryLayout<Int32>.size)
            ),
            "mapping device channel 0"
        )

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
            hardwareSampleRate: hardwareSampleRate,
            hardwareChannelCount: Int(hardwareFormat.mChannelsPerFrame),
            converter: converter,
            sink: sink,
            renderBuffer: renderBuffer
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
