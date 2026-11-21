import AVFoundation
import Foundation

/// Why a file could not be read. Closed and content-free: the case is safe to
/// log and, bucketed, to count; the file name and type are neither.
enum AudioFileError: Error, Equatable, Sendable {
    case unreadable
    case noAudioTrack
    case protectedContent
    case empty
}

struct AudioFileInfo: Sendable, Equatable {
    /// From the container header. It drives the progress bar only; the frames
    /// actually decoded are the truth.
    let estimatedFrames: Int64
    var estimatedSeconds: Double { Double(estimatedFrames) / AudioFileSourceFormat.sampleRate }
}

enum AudioFileSourceFormat {
    static let sampleRate: Double = 16_000
    static let chunkFrames = 16_000
}

/// Reads 16 kHz mono audio in contiguous one-second chunks. Gaps on the
/// source timeline are emitted as silence, so timestamps match the file.
protocol AudioFileReading: Sendable {
    /// Opens the file and validates that it has audio Witness can decode.
    func open() async throws -> AudioFileInfo
    /// The next chunk, or nil once the final chunk has been returned.
    func nextChunk() throws -> MeetingAudioChunk?
    /// Releases the file. Safe to call more than once.
    func close()
}

/// Reads audio files and the audio track of video files with AVAssetReader, so
/// no third-party decoder is involved. Nothing is copied: the file is read where
/// it is and no decoded audio outlives the call that consumed it.
///
/// Calls are serialised by the owning session; the lock only makes that
/// guarantee checkable.
final class AVAssetAudioFileSource: AudioFileReading, @unchecked Sendable {
    private let url: URL
    /// Restricts reading to a stretch of the file, for playing a passage again.
    /// Frames are 16 kHz and chunk positions then count from the start of it.
    private let frameRange: Range<Int64>?
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderOutput?
    private var carry: [Float] = []
    private var pendingBuffer: CMSampleBuffer?
    private var pendingSilence: Int64 = 0
    private var readerFinished = false
    private var nextFrame: Int64 = 0
    private var sequence: UInt64 = 0
    private var finalDelivered = false

    init(url: URL, frameRange: Range<Int64>? = nil) {
        self.url = url
        self.frameRange = frameRange
    }

    func open() async throws -> AudioFileInfo {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        let readable: Bool
        let protected: Bool
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
            readable = try await asset.load(.isReadable)
            protected = try await asset.load(.hasProtectedContent)
        } catch {
            throw AudioFileError.unreadable
        }
        guard !protected else { throw AudioFileError.protectedContent }
        guard readable else { throw AudioFileError.unreadable }
        guard !tracks.isEmpty else { throw AudioFileError.noAudioTrack }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFileSourceFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioFileError.unreadable }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        if let frameRange {
            reader.timeRange = CMTimeRange(
                start: CMTime(value: frameRange.lowerBound, timescale: Int32(AudioFileSourceFormat.sampleRate)),
                duration: CMTime(value: frameRange.upperBound - frameRange.lowerBound, timescale: Int32(AudioFileSourceFormat.sampleRate))
            )
        }
        guard reader.canAdd(output) else { throw AudioFileError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw AudioFileError.unreadable }

        install(reader: reader, output: output)

        let seconds = duration.isNumeric ? max(duration.seconds, 0) : 0
        return AudioFileInfo(estimatedFrames: Int64(seconds * AudioFileSourceFormat.sampleRate))
    }

    private func install(reader: AVAssetReader, output: AVAssetReaderOutput) {
        lock.withLock {
            self.reader = reader
            self.output = output
        }
    }

    func nextChunk() throws -> MeetingAudioChunk? {
        lock.lock()
        defer { lock.unlock() }
        guard let reader, let output else { throw AudioFileError.unreadable }
        guard !finalDelivered else { return nil }
        let size = AudioFileSourceFormat.chunkFrames
        // One frame beyond a full chunk is read before a chunk is released, so
        // the last chunk is known to be the last when it is returned.
        while carry.count <= size, !readerFinished {
            if pendingSilence > 0 {
                let count = Int(min(pendingSilence, Int64(size + 1 - carry.count)))
                carry.append(contentsOf: repeatElement(0, count: count))
                pendingSilence -= Int64(count)
            } else if let buffer = pendingBuffer {
                pendingBuffer = nil
                try append(buffer)
            } else if let buffer = output.copyNextSampleBuffer() {
                let position = startFrame(of: buffer)
                let expected = nextFrame + Int64(carry.count)
                if let position, position - expected > 2 {
                    pendingSilence = position - expected
                    pendingBuffer = buffer
                } else {
                    let overlap = position.map { expected - $0 } ?? 0
                    try append(buffer, dropping: overlap > 2 ? overlap : 0)
                }
            } else {
                readerFinished = true
                if reader.status == .failed { throw AudioFileError.unreadable }
            }
        }
        if carry.isEmpty {
            // Nothing was decoded at all, or the audio ended on a chunk edge
            // that was already delivered as the final chunk.
            if sequence == 0 { throw AudioFileError.empty }
            return nil
        }
        let take = min(size, carry.count)
        let samples = Array(carry.prefix(take))
        carry.removeFirst(take)
        let isFinal = readerFinished && carry.isEmpty
        let chunk = MeetingAudioChunk(
            source: .system,
            sequence: sequence,
            startFrame: nextFrame,
            sampleRate: AudioFileSourceFormat.sampleRate,
            samples: samples,
            isFinal: isFinal
        )
        sequence += 1
        nextFrame += Int64(take)
        finalDelivered = isFinal
        return chunk
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        reader?.cancelReading()
        reader = nil
        output = nil
        carry = []
        pendingBuffer = nil
        pendingSilence = 0
        finalDelivered = true
    }

    private func startFrame(of buffer: CMSampleBuffer) -> Int64? {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard time.isNumeric else { return nil }
        let frame = CMTimeConvertScale(time, timescale: Int32(AudioFileSourceFormat.sampleRate), method: .roundHalfAwayFromZero)
        return frame.value - (frameRange?.lowerBound ?? 0)
    }

    private func append(_ buffer: CMSampleBuffer, dropping overlap: Int64 = 0) throws {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let frameBytes = MemoryLayout<Float>.size
        let available = CMBlockBufferGetDataLength(block) / frameBytes
        let skipped = Int(min(overlap, Int64(available)))
        let count = available - skipped
        guard count > 0 else { return }
        let start = carry.count
        carry.append(contentsOf: repeatElement(0, count: count))
        let status = carry.withUnsafeMutableBytes { destination -> OSStatus in
            guard let base = destination.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: skipped * frameBytes, dataLength: count * frameBytes,
                destination: base + start * frameBytes
            )
        }
        guard status == kCMBlockBufferNoErr else { throw AudioFileError.unreadable }
    }
}
