import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// An independent input-only HAL segment for the experimental meeting path.
/// Permission must already be granted before this service can open the device.
final class MeetingMicrophoneCapture {
    private let hardware: any AudioHardware
    private let permission: any MicrophonePermissionService
    private var unit: AudioUnit?
    private var context: MicrophoneCallbackContext?
    private var initialized = false
    private var running = false

    init(hardware: any AudioHardware = SystemAudioHardware(), permission: any MicrophonePermissionService) {
        self.hardware = hardware
        self.permission = permission
    }

    /// Whether the running segment cancels what the Mac plays. Without it the
    /// microphone hears the other participants through the speakers and the
    /// transcript credits their words to "You".
    private(set) var usesVoiceProcessing = false

    func start(selection: AudioInputSelection) throws -> MeetingAudioBuffer {
        guard unit == nil else { throw SystemAudioCaptureError.invalidState }
        guard permission.currentAuthorization == .authorized else { throw MeetingMicrophoneError.permissionUnavailable }
        guard let resolved = SystemAudioInput.resolve(selection, among: hardware.availableInputDevices(), defaultID: hardware.defaultInputDeviceID()) else {
            throw MeetingMicrophoneError.noInput
        }
        // Voice processing is pickier about formats than the plain unit and
        // which combination it accepts depends on the device, so it is asked
        // twice with decreasing demands. If it will not open, the meeting still
        // records through the direct path; the transcript filter then removes
        // echoed rows on its own.
        var failures: [String] = []
        for setsPlaybackFormat in [true, false] {
            do {
                let buffer = try open(device: resolved.device.id, voiceProcessing: true, setsPlaybackFormat: setsPlaybackFormat)
                usesVoiceProcessing = true
                return buffer
            } catch {
                failures.append("\(error)")
            }
        }
        Log.audio.notice("Meeting voice processing would not open (\(failures.joined(separator: "; "), privacy: .public)); the microphone records directly")
        let buffer = try open(device: resolved.device.id, voiceProcessing: false, setsPlaybackFormat: false)
        usesVoiceProcessing = false
        return buffer
    }

    private func open(device: AudioDeviceID, voiceProcessing: Bool, setsPlaybackFormat: Bool) throws -> MeetingAudioBuffer {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: voiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MeetingMicrophoneError.noInput }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw MeetingMicrophoneError.noInput }
        unit = instance
        do {
            var on: UInt32 = 1
            // Voice processing needs its output half: it is fed silence and
            // gives the canceller the device it plays to.
            var playback: UInt32 = voiceProcessing ? 1 : 0
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &playback, 4))
            var deviceID = device
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, 4))
            var hardwareFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardwareFormat, &formatSize))
            guard hardwareFormat.mSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.mSampleRate, channels: 1, interleaved: false) else {
                throw SystemAudioCaptureError.unsupportedFormat
            }
            var clientFormat = format.streamDescription.pointee
            try check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            if voiceProcessing {
                if setsPlaybackFormat {
                    try check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
                }
                // By default voice processing ducks every other app, which
                // would make the call itself quieter while we record it.
                var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
                try check(AudioUnitSetProperty(instance, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)))
            } else {
                // Voice processing does its own channel handling and rejects a map.
                var channel: Int32 = 0
                try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &channel, 4))
            }
            var maximum: UInt32 = 0
            var maximumSize: UInt32 = 4
            try check(AudioUnitGetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, &maximumSize))
            let frameCapacity = max(maximum, 4096) * 2
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { throw MeetingMicrophoneError.noInput }
            let buffer = MeetingAudioBuffer(capacity: 128, maximumFrames: Int(frameCapacity), sampleRate: format.sampleRate)
            let callbackContext = MicrophoneCallbackContext(unit: instance, pcm: pcm, buffer: buffer)
            context = callbackContext
            var callback = AURenderCallbackStruct(inputProc: meetingMicrophoneIOProc, inputProcRefCon: Unmanaged.passUnretained(callbackContext).toOpaque())
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            if voiceProcessing {
                var silence = AURenderCallbackStruct(inputProc: meetingMicrophoneSilenceProc, inputProcRefCon: nil)
                try check(AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &silence, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            }
            try check(AudioUnitInitialize(instance))
            initialized = true
            try check(AudioOutputUnitStart(instance))
            running = true
            return buffer
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let unit {
            if running { _ = AudioOutputUnitStop(unit) }
            if initialized { _ = AudioUnitUninitialize(unit) }
            _ = AudioComponentInstanceDispose(unit)
        }
        running = false
        initialized = false
        unit = nil
        context = nil
    }

    func pause() throws {
        guard let unit, running else { throw SystemAudioCaptureError.invalidState }
        try check(AudioOutputUnitStop(unit))
        running = false
    }

    func resume() throws {
        guard let unit, initialized, !running else { throw SystemAudioCaptureError.invalidState }
        try check(AudioOutputUnitStart(unit))
        running = true
    }

    deinit { stop() }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioCaptureError.coreAudio(status) }
    }
}

enum MeetingMicrophoneError: Error, Equatable { case permissionUnavailable, noInput }

private final class MicrophoneCallbackContext {
    let unit: AudioUnit
    let pcm: AVAudioPCMBuffer
    let buffer: MeetingAudioBuffer
    init(unit: AudioUnit, pcm: AVAudioPCMBuffer, buffer: MeetingAudioBuffer) {
        self.unit = unit; self.pcm = pcm; self.buffer = buffer
    }
}

private let meetingMicrophoneSilenceProc: AURenderCallback = { _, flags, _, _, _, data in
    if let data {
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
        }
    }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

private let meetingMicrophoneIOProc: AURenderCallback = { ref, flags, time, _, frames, _ in
    let context = Unmanaged<MicrophoneCallbackContext>.fromOpaque(ref).takeUnretainedValue()
    guard frames <= context.pcm.frameCapacity, time.pointee.mFlags.contains(.hostTimeValid) else {
        context.buffer.rejectCallback(frameCount: Int(frames))
        return noErr
    }
    let list = context.pcm.mutableAudioBufferList
    list.pointee.mBuffers.mDataByteSize = frames * 4
    let status = AudioUnitRender(context.unit, flags, time, 1, frames, list)
    guard status == noErr, let channel = context.pcm.floatChannelData?[0] else {
        context.buffer.rejectCallback(frameCount: Int(frames))
        return noErr
    }
    context.buffer.ingest(UnsafeBufferPointer(start: channel, count: Int(frames)), hostTime: time.pointee.mHostTime)
    return noErr
}
