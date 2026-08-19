import AVFoundation
import Foundation

/// Memory-only fragment playback.
///
/// The samples are copied into an `AVAudioPCMBuffer` and scheduled directly on
/// a player node. Nothing is written to a file and no URL is involved, which is
/// what keeps the Phase 1 "capture writes nothing to disk" property true for
/// replay as well.
@MainActor
final class AVAudioEngineFragmentPlayer: AudioFragmentPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private(set) var isPlaying = false

    init() {
        engine.attach(player)
    }

    func play(samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty, sampleRate > 0 else { throw AudioPlaybackError.emptyFragment }

        stop()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioPlaybackError.engineFailure("Unsupported playback format")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw AudioPlaybackError.engineFailure("Could not allocate a playback buffer")
        }

        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Reconnecting only when the format changes keeps repeated replays of
        // the same utterance from tearing the graph down each time.
        if currentFormat != format {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            currentFormat = format
        }

        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            throw AudioPlaybackError.engineFailure(error.localizedDescription)
        }

        isPlaying = true
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts]) { [weak self] in
            Task { @MainActor in self?.isPlaying = false }
        }
        player.play()
        Log.audio.info("Replaying \(samples.count) frames from memory")
    }

    func stop() {
        guard engine.isRunning || isPlaying else { return }
        player.stop()
        isPlaying = false
    }

    deinit {
        // `engine` is main-actor isolated state; tearing the graph down here
        // would need a hop, and the engine stops itself when it deallocates.
    }
}
