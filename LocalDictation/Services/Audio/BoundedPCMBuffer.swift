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

    /// Copies the opening `frames` samples into `destination`, reporting whether
    /// that many have arrived yet.
    ///
    /// Storage fills forward and never wraps, so the first frames are the start
    /// of the utterance rather than whatever the buffer happens to hold at the
    /// moment — which is what makes this readable while a recording is still
    /// running. Allocation-free on purpose: the caller holds the same lock the
    /// real-time thread takes, and a `malloc` under it is exactly the unbounded
    /// stall the capture path is written to avoid.
    func copySamples(firstFrames frames: Int, into destination: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard
            frames > 0,
            frameCount >= frames,
            destination.count >= frames,
            let source = storage.baseAddress,
            let target = destination.baseAddress
        else { return false }
        target.update(from: source, count: frames)
        return true
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
