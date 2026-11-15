import CoreAudio
import Foundation

/// The process IDs here identify Core Audio processes, not individual browser tabs.
struct MeetingAudioProcess: Sendable, Equatable {
    let processID: pid_t
    let audioObjectID: AudioObjectID
    let isProducingOutput: Bool
    let isUsingInput: Bool
    let bundleIdentifier: String?

    init(
        processID: pid_t,
        audioObjectID: AudioObjectID,
        isProducingOutput: Bool,
        isUsingInput: Bool = false,
        bundleIdentifier: String? = nil
    ) {
        self.processID = processID
        self.audioObjectID = audioObjectID
        self.isProducingOutput = isProducingOutput
        self.isUsingInput = isUsingInput
        self.bundleIdentifier = bundleIdentifier
    }
}

protocol MeetingProcessResolving: Sendable {
    func processes() throws -> [MeetingAudioProcess]
    func resolve(processID: pid_t) throws -> MeetingAudioProcess?
}

extension MeetingProcessResolving {
    func resolve(processID: pid_t) throws -> MeetingAudioProcess? {
        try processes().first { $0.processID == processID }
    }
}

enum MeetingProcessError: Error, Equatable {
    case coreAudio(OSStatus)
    case malformedProcessList
}

struct CoreAudioMeetingProcessResolver: MeetingProcessResolving {
    func processes() throws -> [MeetingAudioProcess] {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard Int(size).isMultiple(of: MemoryLayout<AudioObjectID>.size) else {
            throw MeetingProcessError.malformedProcessList
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if !ids.isEmpty {
            let status = ids.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!)
            }
            try check(status)
            guard Int(size).isMultiple(of: MemoryLayout<AudioObjectID>.size), Int(size) <= ids.count * MemoryLayout<AudioObjectID>.size else {
                throw MeetingProcessError.malformedProcessList
            }
            ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }
        // A process may disappear between listing and reading its properties.
        return ids.compactMap { id in
            guard let pid: pid_t = try? value(id, kAudioProcessPropertyPID),
                  let running: UInt32 = try? value(id, kAudioProcessPropertyIsRunningOutput) else { return nil }
            let usingInput: UInt32 = (try? value(id, kAudioProcessPropertyIsRunningInput)) ?? 0
            return MeetingAudioProcess(
                processID: pid,
                audioObjectID: id,
                isProducingOutput: running != 0,
                isUsingInput: usingInput != 0,
                bundleIdentifier: try? stringValue(id, kAudioProcessPropertyBundleID)
            )
        }
    }

    private func value<T: FixedWidthInteger>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = property(selector)
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result))
        guard size == MemoryLayout<T>.size else { throw MeetingProcessError.malformedProcessList }
        return result
    }

    private func stringValue(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = property(selector)
        var result: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &result) {
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0))
        }
        guard size == MemoryLayout<CFString>.size else { throw MeetingProcessError.malformedProcessList }
        return result as String
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MeetingProcessError.coreAudio(status) }
    }
}
