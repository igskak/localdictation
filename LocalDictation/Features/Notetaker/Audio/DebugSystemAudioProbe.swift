#if DEBUG
import CoreAudio
import Darwin
import Foundation

/// Opt-in command-line spike. Output contains only counts, duration and error
/// categories; no samples, process names, bundle identifiers or transcript.
enum DebugSystemAudioProbe {
    static func printProcessInventory(resolver: any MeetingProcessResolving = CoreAudioMeetingProcessResolver()) -> Bool {
        do {
            let processes = try resolver.processes().sorted { $0.processID < $1.processID }
            print("Notetaker audio processes: count=\(processes.count)")
            for process in processes {
                print("pid=\(process.processID) active=\(process.isProducingOutput)")
            }
            return true
        } catch {
            print("Notetaker audio processes: failed category=\(failureCategory(for: error))")
            return false
        }
    }

    static func run(processID: pid_t, durationSeconds: Int, exercisePause: Bool) -> Bool {
        let capture = SystemAudioCapture()
        let origin = AudioGetCurrentHostTime()
        do {
            let buffer = try capture.start(processID: processID)
            var processor = try SystemAudioChunkProcessor(buffer: buffer, inputSampleRate: buffer.sampleRate, originHostTime: origin)
            let started = ProcessInfo.processInfo.systemUptime
            var chunks = 0
            var flushedFrames = 0
            var pausedOnce = false
            print("Notetaker spike recording. Ensure participants have received any required notice or consent.")
            while ProcessInfo.processInfo.systemUptime - started < Double(durationSeconds) {
                while try processor.take() != nil { chunks += 1 }
                if exercisePause && !pausedOnce && ProcessInfo.processInfo.systemUptime - started >= Double(durationSeconds) / 2 {
                    try capture.pause()
                    while try processor.take() != nil { chunks += 1 }
                    flushedFrames += try processor.finish().samples.count
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
            flushedFrames += try processor.finish().samples.count
            let counters = buffer.snapshot()
            print("Notetaker spike: duration=\(durationSeconds)s callbacks=\(counters.receivedCallbacks) chunks=\(chunks) flushedFrames=\(flushedFrames) droppedCallbacks=\(counters.droppedCallbacks) droppedFrames=\(counters.droppedFrames) queuedChunks=\(counters.queuedChunks) peakQueuedChunks=\(counters.peakQueuedChunks)")
            return counters.droppedCallbacks == 0 && counters.receivedCallbacks > 0
        } catch {
            capture.stop()
            print("Notetaker spike: capture failed category=\(failureCategory(for: error))")
            return false
        }
    }

    static func failureCategory(for error: Error) -> String {
        if error as? SystemAudioPermissionError == .denied { return "permission-denied" }
        switch error as? SystemAudioCaptureError {
        case .processNotFound: return "process-not-found"
        case .unsupportedFormat: return "unsupported-format"
        case .invalidState: return "invalid-state"
        case .coreAudio: return "core-audio"
        case nil: return "unexpected"
        }
    }
}
#endif
