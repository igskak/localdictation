#if DEBUG
import CoreAudio
import Darwin
import Foundation

/// Opt-in command-line spike. Output contains only counts, duration and error
/// categories; no samples, process names, bundle identifiers or transcript.
enum DebugSystemAudioProbe {
    static func run(processID: pid_t, durationSeconds: Int, exercisePause: Bool) -> Bool {
        let capture = SystemAudioCapture()
        let origin = AudioGetCurrentHostTime()
        do {
            let buffer = try capture.start(processID: processID)
            var processor = try SystemAudioChunkProcessor(buffer: buffer, inputSampleRate: buffer.sampleRate, originHostTime: origin)
            let started = ProcessInfo.processInfo.systemUptime
            var chunks = 0
            var pausedOnce = false
            print("Notetaker spike recording. Ensure participants have received any required notice or consent.")
            while ProcessInfo.processInfo.systemUptime - started < Double(durationSeconds) {
                while try processor.take() != nil { chunks += 1 }
                if exercisePause && !pausedOnce && ProcessInfo.processInfo.systemUptime - started >= Double(durationSeconds) / 2 {
                    try capture.pause()
                    while try processor.take() != nil { chunks += 1 }
                    _ = try processor.finish()
                    print("Notetaker spike paused")
                    Thread.sleep(forTimeInterval: 1)
                    processor = try SystemAudioChunkProcessor(buffer: buffer, inputSampleRate: buffer.sampleRate, originHostTime: origin)
                    try capture.resume()
                    pausedOnce = true
                    print("Notetaker spike resumed")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            capture.stop()
            while try processor.take() != nil { chunks += 1 }
            _ = try processor.finish()
            let counters = buffer.snapshot()
            print("Notetaker spike: duration=\(durationSeconds)s callbacks=\(counters.receivedCallbacks) chunks=\(chunks) droppedCallbacks=\(counters.droppedCallbacks) droppedFrames=\(counters.droppedFrames)")
            return counters.droppedCallbacks == 0 && counters.receivedCallbacks > 0
        } catch {
            capture.stop()
            print("Notetaker spike: capture failed")
            return false
        }
    }
}
#endif
