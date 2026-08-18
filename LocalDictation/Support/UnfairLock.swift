import os

/// Minimal wrapper around `os_unfair_lock`.
///
/// The real-time audio thread uses this to publish capture progress. Critical
/// sections must stay a bounded `memcpy` plus fixed-cost arithmetic so the audio
/// callback never waits on allocation, the file system, or the main actor.
final class UnfairLock: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    init() {
        storage = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return try body()
    }
}
