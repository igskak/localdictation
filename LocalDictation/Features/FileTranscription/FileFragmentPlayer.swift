import AVFoundation
import Foundation

enum FragmentReplayError: Error, Equatable {
    /// The file the note was made from is no longer where it was.
    case fileMissing
    case unreadable
}

/// 16-bit mono PCM in a WAV container, built in memory for `AVAudioPlayer`.
enum PCMWave {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clipped = sample.isFinite ? max(-1, min(1, sample)) : 0
            var value = Int16((clipped * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        var header = Data("RIFF".utf8)
        header += le32(36 + pcm.count)
        header += Data("WAVEfmt ".utf8)
        header += le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        header += Data("data".utf8) + le32(pcm.count)
        return header + pcm
    }
}

/// Plays one passage of the file a note was made from. Witness keeps no audio,
/// so the passage is decoded from the original again, played, and dropped. If
/// the file has moved the answer is a named error, never silence.
@MainActor
final class FileFragmentPlayer {
    /// Longer than any recognised row; a stored range beyond it is corrupt.
    static let maximumFragmentSeconds: Int64 = 120

    private var player: AVAudioPlayer?
    private var playback = UUID()

    func play(file: MeetingSourceFile, startFrame: Int64, endFrame: Int64) async throws {
        stop()
        let request = playback
        let url = URL(fileURLWithPath: file.path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw FragmentReplayError.fileMissing }
        guard endFrame > startFrame, endFrame - startFrame <= Self.maximumFragmentSeconds * 16_000 else {
            throw FragmentReplayError.unreadable
        }
        let samples: [Float]
        do {
            samples = try await Self.decode(url: url, startFrame: startFrame, endFrame: endFrame)
        } catch {
            guard request == playback else { throw CancellationError() }
            throw error
        }
        guard request == playback else { throw CancellationError() }
        guard !samples.isEmpty else { throw FragmentReplayError.unreadable }
        do {
            let player = try AVAudioPlayer(data: PCMWave.data(samples: samples, sampleRate: 16_000))
            guard player.play() else { throw FragmentReplayError.unreadable }
            self.player = player
        } catch {
            throw FragmentReplayError.unreadable
        }
    }

    func stop() {
        playback = UUID()
        player?.stop()
        player = nil
    }

    nonisolated static func decode(url: URL, startFrame: Int64, endFrame: Int64) async throws -> [Float] {
        let source = AVAssetAudioFileSource(url: url, frameRange: startFrame..<endFrame)
        do { _ = try await source.open() } catch { throw FragmentReplayError.unreadable }
        defer { source.close() }
        var samples: [Float] = []
        do {
            while let chunk = try source.nextChunk() { samples += chunk.samples }
        } catch {
            throw FragmentReplayError.unreadable
        }
        return Array(samples.prefix(Int(endFrame - startFrame)))
    }
}
