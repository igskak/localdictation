import Foundation

/// Fixed-capacity Float32 sample buffer with preallocated storage.
///
/// Appending never allocates and never grows: once capacity is reached the extra
/// frames are counted as dropped so the diagnostics can surface the truncation.
/// The type is not thread-safe on its own; `PCMCaptureSink` provides the lock.
final class BoundedPCMBuffer {
    struct AppendResult: Sendable, Equatable {
        let acceptedFrames: Int
        let droppedFrames: Int
    }

    let capacityFrames: Int

    private let storage: UnsafeMutableBufferPointer<Float>
    private(set) var frameCount: Int = 0
    private(set) var droppedFrameCount: Int = 0
    private(set) var peakLevel: Float = 0

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0, "Capture buffer capacity must be positive")
        self.capacityFrames = capacityFrames
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    var isFull: Bool { frameCount >= capacityFrames }
    var remainingFrames: Int { capacityFrames - frameCount }

    @discardableResult
    func append(_ frames: UnsafeBufferPointer<Float>) -> AppendResult {
        guard let source = frames.baseAddress, !frames.isEmpty else {
            return AppendResult(acceptedFrames: 0, droppedFrames: 0)
        }

        let accepted = min(remainingFrames, frames.count)
        if accepted > 0, let destination = storage.baseAddress {
            destination.advanced(by: frameCount).update(from: source, count: accepted)
            var peak = peakLevel
            for index in 0..<accepted {
                let magnitude = abs(source[index])
                if magnitude > peak { peak = magnitude }
            }
            peakLevel = peak
            frameCount += accepted
        }

        let dropped = frames.count - accepted
        droppedFrameCount += dropped
        return AppendResult(acceptedFrames: accepted, droppedFrames: dropped)
    }

    @discardableResult
    func append(_ frames: [Float]) -> AppendResult {
        frames.withUnsafeBufferPointer { append($0) }
    }

    /// Copies the captured frames out. Called once per utterance, off the
    /// real-time thread.
    func makeSamples() -> [Float] {
        guard frameCount > 0, let base = storage.baseAddress else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: frameCount))
    }

    func withSamples<T>(_ body: (UnsafeBufferPointer<Float>) throws -> T) rethrows -> T {
        try body(UnsafeBufferPointer(start: storage.baseAddress, count: frameCount))
    }

    func reset() {
        frameCount = 0
        droppedFrameCount = 0
        peakLevel = 0
    }
}
