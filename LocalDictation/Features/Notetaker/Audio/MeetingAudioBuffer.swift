import CoreAudio
import Darwin
import Foundation
import os.lock

struct SystemAudioChunk: Sendable {
    let sequence: UInt64
    let hostTime: UInt64
    let sampleRate: Double
    let samples: [Float]
}

struct SystemAudioBufferCounters: Sendable, Equatable {
    let receivedCallbacks: Int64
    let droppedCallbacks: Int64
    let droppedFrames: Int64
    let queuedChunks: Int
}

/// Single producer, single consumer. The producer never waits: contention and
/// overflow are counted, so a missing audio interval is never silently hidden.
final class MeetingAudioBuffer: @unchecked Sendable {
    private struct Slot {
        var sequence: UInt64 = 0
        var hostTime: UInt64 = 0
        var count: Int = 0
    }
    private let capacity: Int
    private let maximumFrames: Int
    let sampleRate: Double
    private let storage: UnsafeMutablePointer<Float>
    private var slots: [Slot]
    private var lock = os_unfair_lock_s()
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    // Updated atomically, including when trylock fails.
    private var callbacks: Int64 = 0
    private var dropped: Int64 = 0
    private var lostFrames: Int64 = 0

    init(capacity: Int, maximumFrames: Int, sampleRate: Double) {
        precondition(capacity > 0 && maximumFrames > 0 && sampleRate > 0)
        self.capacity = capacity
        self.maximumFrames = maximumFrames
        self.sampleRate = sampleRate
        self.storage = .allocate(capacity: capacity * maximumFrames)
        self.slots = Array(repeating: Slot(), count: capacity)
    }

    deinit { storage.deallocate() }

    /// Called only from the audio thread; copies into preallocated storage.
    func ingest(_ frames: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        let sequence = UInt64(OSAtomicIncrement64Barrier(&callbacks) - 1)
        guard frames.count <= maximumFrames, os_unfair_lock_trylock(&lock) else {
            OSAtomicIncrement64Barrier(&dropped)
            OSAtomicAdd64Barrier(Int64(frames.count), &lostFrames)
            return
        }
        defer { os_unfair_lock_unlock(&lock) }
        guard count < capacity else {
            OSAtomicIncrement64Barrier(&dropped)
            OSAtomicAdd64Barrier(Int64(frames.count), &lostFrames)
            return
        }
        if let source = frames.baseAddress, !frames.isEmpty {
            (storage + writeIndex * maximumFrames).update(from: source, count: frames.count)
        }
        slots[writeIndex] = Slot(sequence: sequence, hostTime: hostTime, count: frames.count)
        writeIndex = (writeIndex + 1) % capacity
        count += 1
    }

    /// An unusable callback is observable even when its duration is unknown.
    func rejectCallback(frameCount: Int) {
        OSAtomicIncrement64Barrier(&callbacks)
        OSAtomicIncrement64Barrier(&dropped)
        OSAtomicAdd64Barrier(Int64(max(0, frameCount)), &lostFrames)
    }

    /// Call off the real-time thread. Every call copies at most one bounded slot.
    func take() -> SystemAudioChunk? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else { return nil }
        let slot = slots[readIndex]
        let samples = Array(UnsafeBufferPointer(start: storage + readIndex * maximumFrames, count: slot.count))
        readIndex = (readIndex + 1) % capacity
        count -= 1
        return SystemAudioChunk(sequence: slot.sequence, hostTime: slot.hostTime, sampleRate: sampleRate, samples: samples)
    }

    func snapshot() -> SystemAudioBufferCounters {
        os_unfair_lock_lock(&lock)
        let queued = count
        os_unfair_lock_unlock(&lock)
        return SystemAudioBufferCounters(
            receivedCallbacks: OSAtomicAdd64Barrier(0, &callbacks),
            droppedCallbacks: OSAtomicAdd64Barrier(0, &dropped),
            droppedFrames: OSAtomicAdd64Barrier(0, &lostFrames),
            queuedChunks: queued
        )
    }
}
