import AudioToolbox
import CoreAudio
import Foundation

/// Apple requests system-audio access when an aggregate device containing a
/// process tap is first started; there is no separate prompt in this boundary.
protocol SystemAudioPermissionService: Sendable {
    func startCapture(_ operation: @Sendable () -> OSStatus) throws
}

struct LiveSystemAudioPermissionService: SystemAudioPermissionService {
    func startCapture(_ operation: @Sendable () -> OSStatus) throws {
        let status = operation()
        switch status {
        case noErr:
            return
        case kAudioDevicePermissionsError:
            throw SystemAudioPermissionError.denied
        default:
            throw SystemAudioCaptureError.coreAudio(status)
        }
    }
}

enum SystemAudioPermissionError: Error, Equatable {
    case denied
}

enum SystemAudioCaptureError: Error, Equatable {
    case processNotFound
    case unsupportedFormat
    case invalidState
    case discontinuity
    case coreAudio(OSStatus)
}

/// Owns a private Core Audio tap and an aggregate device. Lifecycle methods are
/// serialized by the caller; nothing starts until an explicit `start` call.
final class SystemAudioCapture {
    private let resolver: any MeetingProcessResolving
    private let permission: any SystemAudioPermissionService
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var device: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var context: TapCallbackContext?
    private var running = false

    init(resolver: any MeetingProcessResolving = CoreAudioMeetingProcessResolver(),
         permission: any SystemAudioPermissionService = LiveSystemAudioPermissionService()) {
        self.resolver = resolver
        self.permission = permission
    }

    func start(processID: pid_t, queueCapacity: Int = 128, maximumFrames: Int = 8192) throws -> MeetingAudioBuffer {
        guard tap == kAudioObjectUnknown else { throw SystemAudioCaptureError.invalidState }
        guard let process = try resolver.resolve(processID: processID) else { throw SystemAudioCaptureError.processNotFound }
        do {
            let description = CATapDescription(monoMixdownOfProcesses: [process.audioObjectID])
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap))
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame == 1,
                  format.mBytesPerFrame == 4, format.mSampleRate > 0 else {
                throw SystemAudioCaptureError.unsupportedFormat
            }
            var uid: CFString = "" as CFString
            size = UInt32(MemoryLayout<CFString>.size)
            address.mSelector = kAudioTapPropertyUID
            try withUnsafeMutablePointer(to: &uid) { try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, $0)) }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Witness Notetaker Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
            let buffer = MeetingAudioBuffer(capacity: queueCapacity, maximumFrames: maximumFrames, sampleRate: format.mSampleRate)
            let context = TapCallbackContext(buffer: buffer)
            self.context = context
            try check(AudioDeviceCreateIOProcID(device, systemAudioIOProc, Unmanaged.passUnretained(context).toOpaque(), &ioProc))
            let device = self.device
            let proc = self.ioProc
            try permission.startCapture { AudioDeviceStart(device, proc) }
            running = true
            return buffer
        } catch {
            stop()
            throw error
        }
    }

    func pause() throws {
        guard running else { throw SystemAudioCaptureError.invalidState }
        try check(AudioDeviceStop(device, ioProc))
        running = false
    }

    func resume() throws {
        guard device != kAudioObjectUnknown, !running else { throw SystemAudioCaptureError.invalidState }
        let device = self.device
        let proc = self.ioProc
        try permission.startCapture { AudioDeviceStart(device, proc) }
        running = true
    }

    /// Stops callbacks before releasing their context. The caller drains the
    /// returned buffer after stop; no audio is written to disk.
    func stop() {
        if running { _ = AudioDeviceStop(device, ioProc); running = false }
        if device != kAudioObjectUnknown {
            if let ioProc { _ = AudioDeviceDestroyIOProcID(device, ioProc) }
            _ = AudioHardwareDestroyAggregateDevice(device)
        }
        ioProc = nil
        device = kAudioObjectUnknown
        context = nil
        if tap != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tap) }
        tap = kAudioObjectUnknown
    }

    deinit { stop() }
    private func check(_ status: OSStatus) throws { try Self.checkStatus(status) }
    private static func checkStatus(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioCaptureError.coreAudio(status) }
    }
}

private final class TapCallbackContext {
    let buffer: MeetingAudioBuffer
    init(buffer: MeetingAudioBuffer) { self.buffer = buffer }
}

private let systemAudioIOProc: AudioDeviceIOProc = { _, _, input, inputTime, _, _, userData in
    guard let userData else { return noErr }
    let context = Unmanaged<TapCallbackContext>.fromOpaque(userData).takeUnretainedValue()
    let audio = input.pointee.mBuffers
    guard input.pointee.mNumberBuffers == 1, audio.mNumberChannels == 1,
          inputTime.pointee.mFlags.contains(.hostTimeValid),
          audio.mDataByteSize.isMultiple(of: 4), let data = audio.mData else {
        context.buffer.rejectCallback(frameCount: Int(audio.mDataByteSize) / MemoryLayout<Float>.size)
        return noErr
    }
    let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
    context.buffer.ingest(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), hostTime: inputTime.pointee.mHostTime)
    return noErr
}
