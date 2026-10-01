// Asks why a Bluetooth microphone records nothing while another host owns the
// headset, and which claim takes it back.
//
// The case: AirPods paired to both this Mac and a phone, music playing from the
// phone. Witness opens the AirPods input and gets nothing; Wispr Flow stops the
// music and records. Something in the way Wispr opens the device takes the
// headset away from the phone, and this probe is how we find out what.
//
// Run directly, no project build required:
//
//     swift Tools/probe_bluetooth_input.swift
//     swift Tools/probe_bluetooth_input.swift --device AirPods --seconds 5
//
// Four phases, each reporting callbacks, frames and level:
//
//   0  built-in microphone, input only          control: proves the probe can hear
//   A  target device, input only                what Witness does today
//   B  target device, input + silent output      a full-duplex claim on one device
//   C  target device, voice processing IO        what a call does
//
// Nothing is persisted and nothing leaves the machine: the probe prints levels,
// never samples. It changes no system setting; it binds devices explicitly and
// never touches the default input or output.
//
// The microphone permission belongs to the terminal that runs this, not to
// Witness, so phase 0 is not optional: zeros everywhere mean the terminal has
// no microphone access and the rest of the run says nothing about Bluetooth.
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - Arguments

var requestedDevice: String?
var phaseSeconds: Double = 4
var pauseBetweenPhases = true
/// Which phases to run, by letter. Phase B is pointless on a device that reports
/// no output streams, and once a phase has answered there is no reason to pay
/// for it again.
var phases = "0abc"

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--device":
        requestedDevice = arguments.first
        if !arguments.isEmpty { arguments.removeFirst() }
    case "--seconds":
        if let value = arguments.first, let seconds = Double(value), seconds > 0 { phaseSeconds = seconds }
        if !arguments.isEmpty { arguments.removeFirst() }
    case "--no-pause":
        pauseBetweenPhases = false
    case "--phases":
        if let value = arguments.first { phases = value.lowercased() }
        if !arguments.isEmpty { arguments.removeFirst() }
    case "--help", "-h":
        print("""
        usage: swift Tools/probe_bluetooth_input.swift [--device <name or uid substring>]
                                                      [--seconds <per phase, default 4>]
                                                      [--phases 0abc]
                                                      [--no-pause]
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
        exit(2)
    }
}

// MARK: - Core Audio reading

func uint32Property(_ selector: AudioObjectPropertySelector, of id: AudioObjectID, default fallback: UInt32 = 0) -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = fallback
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return fallback }
    return value
}

func doubleProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
    return value
}

func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
    guard status == noErr else { return nil }
    return value as String?
}

func channelCount(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportName(_ transport: UInt32) -> String {
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn: "built-in"
    case kAudioDeviceTransportTypeBluetooth: "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: "bluetooth-le"
    case kAudioDeviceTransportTypeUSB: "usb"
    case kAudioDeviceTransportTypeAggregate: "aggregate"
    case kAudioDeviceTransportTypeVirtual: "virtual"
    case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity"
    default: "other"
    }
}

struct Device {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    var inputChannels: Int { channelCount(of: id, scope: kAudioDevicePropertyScopeInput) }
    var outputChannels: Int { channelCount(of: id, scope: kAudioDevicePropertyScopeOutput) }
    var sampleRate: Double { doubleProperty(kAudioDevicePropertyNominalSampleRate, of: id) }
    var isAlive: Bool { uint32Property(kAudioDevicePropertyDeviceIsAlive, of: id) == 1 }
    var isRunningSomewhere: Bool { uint32Property(kAudioDevicePropertyDeviceIsRunningSomewhere, of: id) == 1 }
}

func allDevices() -> [Device] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
    guard count > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
    let status = ids.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { return [] }
    return ids.compactMap { id in
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
              let name = stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
        return Device(id: id, uid: uid, name: name, transport: uint32Property(kAudioDevicePropertyTransportType, of: id, default: kAudioDeviceTransportTypeUnknown))
    }
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    uint32Property(selector, of: AudioObjectID(kAudioObjectSystemObject), default: AudioDeviceID(kAudioObjectUnknown))
}

// MARK: - Level accumulation, written by the IO thread

final class Meter: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var callbacks = 0
    private var frames = 0
    private var peak: Float = 0
    private var sumOfSquares: Double = 0
    private var firstCallbackAt: TimeInterval?
    private var renderStatus: OSStatus = noErr

    func record(samples: UnsafePointer<Float>, count: Int, at uptime: TimeInterval) {
        var localPeak: Float = 0
        var localSum: Double = 0
        for index in 0..<count {
            let value = samples[index]
            let magnitude = abs(value)
            if magnitude > localPeak { localPeak = magnitude }
            localSum += Double(value) * Double(value)
        }
        os_unfair_lock_lock(&lock)
        callbacks += 1
        frames += count
        if localPeak > peak { peak = localPeak }
        sumOfSquares += localSum
        if firstCallbackAt == nil { firstCallbackAt = uptime }
        os_unfair_lock_unlock(&lock)
    }

    func record(failure: OSStatus) {
        os_unfair_lock_lock(&lock)
        if renderStatus == noErr { renderStatus = failure }
        os_unfair_lock_unlock(&lock)
    }

    struct Reading {
        var callbacks: Int
        var frames: Int
        var peak: Float
        var rms: Double
        var firstCallbackAt: TimeInterval?
        var renderStatus: OSStatus
    }

    func read() -> Reading {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let rms = frames > 0 ? (sumOfSquares / Double(frames)).squareRoot() : 0
        return Reading(callbacks: callbacks, frames: frames, peak: peak, rms: rms, firstCallbackAt: firstCallbackAt, renderStatus: renderStatus)
    }
}

func decibels(_ amplitude: Double) -> String {
    guard amplitude > 0 else { return "   -inf" }
    return String(format: "%7.1f", 20 * log10(amplitude))
}

// MARK: - Input unit, built the way capture builds it

final class InputClaim {
    let unit: AudioUnit
    let meter = Meter()
    let hardwareRate: Double
    let hardwareChannels: Int
    let buffer: AVAudioPCMBuffer
    let startedAt: TimeInterval
    private(set) var clientChannels = 1
    private(set) var clientRate: Double = 0

    init(device: Device, voiceProcessing: Bool, setOutputFormat: Bool = true, setInputFormat: Bool = true) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: voiceProcessing ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure("no audio component") }
        var instance: AudioUnit?
        try Failure.check(AudioComponentInstanceNew(component, &instance), "instantiating")
        guard let unit = instance else { throw Failure("no audio unit") }
        self.unit = unit

        var on: UInt32 = 1
        try Failure.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, UInt32(MemoryLayout<UInt32>.size)), "enabling input")
        // Voice processing needs its output half: that is what makes it a call
        // rather than a recording, and the whole question here is whether a call
        // is what takes the headset back.
        var output: UInt32 = voiceProcessing ? 1 : 0
        try Failure.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &output, UInt32(MemoryLayout<UInt32>.size)), "setting output")

        var deviceID = device.id
        try Failure.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "selecting the device")

        var hardwareFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Failure.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardwareFormat, &formatSize), "reading the hardware format")
        hardwareRate = hardwareFormat.mSampleRate > 0 ? hardwareFormat.mSampleRate : device.sampleRate
        hardwareChannels = Int(hardwareFormat.mChannelsPerFrame)
        guard hardwareRate > 0 else { throw Failure("hardware rate is 0") }

        guard let clientFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareRate, channels: 1, interleaved: false) else {
            throw Failure("no client format")
        }
        var clientDescription = clientFormat.streamDescription.pointee
        if setInputFormat {
            try Failure.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "setting the client input format")
        }
        if voiceProcessing {
            // Its output half is fed silence, so the format has to be set there
            // too. Voice processing is pickier than the plain unit about which
            // formats it will take, hence the retries in phase C.
            if setOutputFormat {
                try Failure.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &clientDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "setting the client output format")
            }
        } else {
            var channelMap: Int32 = 0
            try Failure.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &channelMap, UInt32(MemoryLayout<Int32>.size)), "mapping channel 0")
        }

        var maximumFrames: UInt32 = 0
        var maximumFramesSize = UInt32(MemoryLayout<UInt32>.size)
        try Failure.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, &maximumFramesSize), "reading the slice size")
        // Whatever the unit ended up with on its client side, not what we asked
        // for: with the format retries in phase C those can differ.
        var settledFormat = AudioStreamBasicDescription()
        var settledSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &settledFormat, &settledSize) != noErr {
            settledFormat = clientDescription
        }
        guard let settled = AVAudioFormat(streamDescription: &settledFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: settled, frameCapacity: AVAudioFrameCount(max(maximumFrames, 4096)) * 2) else {
            throw Failure("no render buffer")
        }
        clientChannels = Int(settledFormat.mChannelsPerFrame)
        clientRate = settledFormat.mSampleRate
        self.buffer = buffer

        var inputCallback = AURenderCallbackStruct(inputProc: probeInputCallback, inputProcRefCon: nil)
        var renderCallback = AURenderCallbackStruct(inputProc: probeSilenceCallback, inputProcRefCon: nil)
        startedAt = ProcessInfo.processInfo.systemUptime
        inputCallback.inputProcRefCon = Unmanaged.passUnretained(self).toOpaque()
        try Failure.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "installing the input callback")
        if voiceProcessing {
            try Failure.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "installing the silence callback")
        }
        try Failure.check(AudioUnitInitialize(unit), "initializing")
    }

    func start() throws { try Failure.check(AudioOutputUnitStart(unit), "starting") }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

/// An output-only unit on the same device, fed silence. The point is the claim,
/// not the sound: it is what the probe uses to ask whether owning the output
/// half is what pulls a shared headset back from the other host.
final class SilentOutputClaim {
    let unit: AudioUnit

    init(device: Device) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure("no audio component") }
        var instance: AudioUnit?
        try Failure.check(AudioComponentInstanceNew(component, &instance), "instantiating the output unit")
        guard let unit = instance else { throw Failure("no output unit") }
        self.unit = unit

        var deviceID = device.id
        try Failure.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "selecting the output device")
        var callback = AURenderCallbackStruct(inputProc: probeSilenceCallback, inputProcRefCon: nil)
        try Failure.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "installing the silence callback")
        try Failure.check(AudioUnitInitialize(unit), "initializing the output unit")
    }

    func start() throws { try Failure.check(AudioOutputUnitStart(unit), "starting the output unit") }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
    static func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw Failure("\(what) failed with Core Audio status \(status)")
    }
}

func probeInputCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frameCount: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let claim = Unmanaged<InputClaim>.fromOpaque(refCon).takeUnretainedValue()
    guard frameCount > 0, frameCount <= claim.buffer.frameCapacity else { return noErr }
    let list = claim.buffer.mutableAudioBufferList
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    for index in 0..<buffers.count {
        buffers[index].mDataByteSize = frameCount * 4 * UInt32(buffers[index].mNumberChannels)
    }
    let status = AudioUnitRender(claim.unit, flags, timestamp, 1, frameCount, list)
    guard status == noErr else {
        claim.meter.record(failure: status)
        return status
    }
    guard let samples = claim.buffer.floatChannelData?[0] else { return noErr }
    // Channel 0 either way: for a non-interleaved buffer that is the first
    // channel, and the probe only ever asks for mono.
    claim.meter.record(samples: samples, count: Int(frameCount), at: ProcessInfo.processInfo.systemUptime)
    return noErr
}

func probeSilenceCallback(
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
        memset(buffer.mData, 0, Int(buffer.mDataByteSize))
    }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

// MARK: - Permission

func ensureMicrophonePermission() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        print("Asking this terminal for microphone access; allow it in the dialog.")
        let gate = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; gate.signal() }
        gate.wait()
        if granted { return }
        print("Microphone access refused. Every level below would read as silence, so nothing would be measured.")
        exit(1)
    default:
        print("""
        This terminal has no microphone access, so every level below would read as
        silence and the run would say nothing about Bluetooth. Grant it under
        System Settings -> Privacy & Security -> Microphone, then run again.
        """)
        exit(1)
    }
}

// MARK: - Phases

func describe(_ device: Device, label: String) {
    let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    var roles: [String] = []
    if device.id == defaultInput { roles.append("default input") }
    if device.id == defaultOutput { roles.append("default output") }
    if device.isRunningSomewhere { roles.append("running somewhere") }
    print("  \(label): \(device.name) [\(transportName(device.transport))] "
        + "\(Int(device.sampleRate)) Hz, in \(device.inputChannels) ch, out \(device.outputChannels) ch"
        + (roles.isEmpty ? "" : ", \(roles.joined(separator: ", "))"))
}

func report(_ name: String, _ reading: Meter.Reading, startedAt: TimeInterval, note: String? = nil) {
    let latency = reading.firstCallbackAt.map { String(format: "%.0f ms", ($0 - startedAt) * 1000) } ?? "never"
    print("  \(name): callbacks \(reading.callbacks), frames \(reading.frames), "
        + "first callback \(latency), peak \(decibels(Double(reading.peak))) dBFS, rms \(decibels(reading.rms)) dBFS"
        + (reading.renderStatus != noErr ? ", render status \(reading.renderStatus)" : ""))
    if let note { print("  \(note)") }
}

/// False when the operator asked to skip the phase this announces.
func announce(_ instruction: String) -> Bool {
    print("\n\(instruction)")
    guard pauseBetweenPhases else { return true }
    print("  press Return to continue, or type s and Return to skip this phase: ", terminator: "")
    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer != "s"
}

func run(seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}

// MARK: - Main

ensureMicrophonePermission()

let devices = allDevices()
let inputs = devices.filter { $0.inputChannels > 0 }
guard !inputs.isEmpty else {
    print("No input devices.")
    exit(1)
}

print("Devices with input streams")
for device in inputs { describe(device, label: "·") }
print()

let target: Device
if let requested = requestedDevice {
    guard let match = inputs.first(where: { $0.name.localizedCaseInsensitiveContains(requested) || $0.uid.localizedCaseInsensitiveContains(requested) }) else {
        print("No input device matches \"\(requested)\".")
        exit(1)
    }
    target = match
} else if let bluetooth = inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE }) {
    target = bluetooth
} else {
    print("No Bluetooth input device is connected. Connect the headset and run again, or pass --device.")
    exit(1)
}

let builtIn = inputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }

print("Target: \(target.name) [\(transportName(target.transport))]")
print("Phases \(phases.map(String.init).joined(separator: " ")), \(String(format: "%.0f", phaseSeconds)) s each. Speak during every phase, and after each one")
print("note whether the music from the other device is still playing.\n")

// Phase 0: the control. Without it, zeros below could just be a missing permission.
if let builtIn, phases.contains("0") {
    print("Phase 0  built-in microphone, input only (control)")
    describe(builtIn, label: "device")
    do {
        let claim = try InputClaim(device: builtIn, voiceProcessing: false)
        try claim.start()
        run(seconds: min(phaseSeconds, 2))
        let reading = claim.meter.read()
        claim.stop()
        report("result", reading, startedAt: claim.startedAt,
               note: reading.peak == 0 ? "SILENT. The control heard nothing, so this run cannot measure the headset." : nil)
    } catch {
        print("  failed: \((error as? Failure)?.message ?? "\(error)")")
    }
    print()
}

// Phase A: exactly what capture does today.
if phases.contains("a"), announce("Phase A opens \(target.name) input only, the way Witness does. Start the music on the other device first.") {
    print("Phase A  \(target.name), input only")
    describe(target, label: "before")
    do {
        let claim = try InputClaim(device: target, voiceProcessing: false)
        try claim.start()
        print("  opened at \(Int(claim.hardwareRate)) Hz \(claim.hardwareChannels) ch; speak now")
        run(seconds: phaseSeconds)
        let reading = claim.meter.read()
        describe(target, label: "during")
        claim.stop()
        report("result", reading, startedAt: claim.startedAt)
    } catch {
        print("  failed: \((error as? Failure)?.message ?? "\(error)")")
    }
    print()
}

// Phase B: the same input, plus the output half of the same device.
if phases.contains("b"), announce("Phase B adds a silent output on \(target.name) to the same input. Make sure the music is playing again.") {
    print("Phase B  \(target.name), input + silent output on the same device")
    describe(target, label: "before")
    if target.outputChannels == 0 {
        print("  skipped: this device has no output streams, so there is no output half to claim")
    }
    do {
        guard target.outputChannels > 0 else { throw Failure("no output streams") }
        let claim = try InputClaim(device: target, voiceProcessing: false)
        try claim.start()
        print("  input opened at \(Int(claim.hardwareRate)) Hz \(claim.hardwareChannels) ch")
        run(seconds: min(1, phaseSeconds / 4))
        let beforeOutput = claim.meter.read()
        let output = try SilentOutputClaim(device: target)
        try output.start()
        print("  silent output started; speak now")
        run(seconds: phaseSeconds)
        let reading = claim.meter.read()
        describe(target, label: "during")
        output.stop()
        claim.stop()
        report("input only, first second", beforeOutput, startedAt: claim.startedAt)
        report("after the output claim", reading, startedAt: claim.startedAt)
    } catch let failure as Failure where failure.message == "no output streams" {
        // Already reported above.
    } catch {
        print("  failed: \((error as? Failure)?.message ?? "\(error)")")
    }
    print()
}

// Phase C: what a call does.
if phases.contains("c"), announce("Phase C opens \(target.name) with voice processing, the way a call does. Make sure the music is playing again.") {
    print("Phase C  \(target.name), voice processing IO")
    describe(target, label: "before")
    // Voice processing refuses some format combinations outright, and which it
    // takes depends on the device. Ask for less until it initializes, and say
    // which attempt did.
    let attempts: [(String, Bool, Bool)] = [
        ("mono client on both halves", true, true),
        ("mono input, the unit's own output format", false, true),
        ("the unit's own formats", false, false),
    ]
    var opened: (InputClaim, String)?
    for (label, setOutput, setInput) in attempts {
        do {
            let claim = try InputClaim(device: target, voiceProcessing: true, setOutputFormat: setOutput, setInputFormat: setInput)
            try claim.start()
            opened = (claim, label)
            break
        } catch {
            print("  \(label): \((error as? Failure)?.message ?? "\(error)")")
        }
    }
    if let (claim, label) = opened {
        print("  initialized with \(label): device \(Int(claim.hardwareRate)) Hz \(claim.hardwareChannels) ch, "
            + "client \(Int(claim.clientRate)) Hz \(claim.clientChannels) ch; speak now")
        run(seconds: phaseSeconds)
        let reading = claim.meter.read()
        describe(target, label: "during")
        claim.stop()
        report("result", reading, startedAt: claim.startedAt)
    }
    print()
}

print("""
How to read this. Phase 0 must show speech, or nothing else counts. A phase that
reports callbacks but a level near the noise floor means the headset answered the
Mac without handing over its microphone. The phase where the music stops and the
level rises is the claim worth building into capture.
""")
