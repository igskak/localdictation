#if DEBUG
import Darwin
import Foundation

/// `--transcribe-file <path>` for a Debug build: runs the offline engine on one
/// file without any product UI, prints progress and metrics, and optionally
/// writes the plain transcript and a metrics JSON for the benchmark scripts.
///
///     --transcribe-file PATH [--language de] [--window-min 15] [--window-max 28]
///     [--store-dir DIR] [--transcript-out FILE] [--json-out FILE]
///
/// The note goes to `--store-dir` when given, otherwise to the real library,
/// exactly as a product run would write it. This is local text only; the
/// harness has no network code and the audio is read where it is.
enum FileTranscriptionHarness {
    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--transcribe-file") else { return 2 }
        let language = SpeechLanguage(rawValue: value("--language") ?? "de") ?? SpeechLanguage.german
        let profile = LanguageProfile(language)
        var sizes = FileWindowSizes.file
        if let minimum = value("--window-min").flatMap(Double.init), let maximum = value("--window-max").flatMap(Double.init) {
            // Whole 20 ms energy frames, so a given number of seconds is rounded to one.
            func frames(_ seconds: Double) -> Int { Int((seconds * 16_000 / 320).rounded()) * 320 }
            sizes = FileWindowSizes(minimumFrames: frames(minimum), maximumFrames: frames(maximum), pauseFrames: sizes.pauseFrames)
        }
        let store = value("--store-dir").map { FileMeetingStore(rootURL: URL(fileURLWithPath: $0, isDirectory: true)) } ?? FileMeetingStore()
        let url = URL(fileURLWithPath: path)
        let engine = WhisperKitTranscriptionService(logsInference: false)
        let lastPrinted = LockedValue<Int>(-1)
        let session = FileTranscriptionSession(
            source: AVAssetAudioFileSource(url: url),
            engine: engine,
            profile: profile,
            persistence: MeetingPersistenceRecorder(store: store),
            title: url.deletingPathExtension().lastPathComponent,
            originalFile: url,
            sizes: sizes,
            emit: { progress in
                let percent = Int(progress.fraction * 10) * 10
                guard lastPrinted.exchange(percent) != percent else { return }
                let left = progress.remaining.map { String(format: "%.0f s left", $0) } ?? "estimating"
                FileHandle.standardError.write(Data(String(format: "%3d%%  %.0f s elapsed, %@\n", percent, progress.elapsed, left).utf8))
            }
        )
        do {
            let result = try await session.run()
            let metrics = result.metrics
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let maxResident = Double(usage.ru_maxrss) / 1_048_576
            let report: [String: Any] = [
                "file": url.lastPathComponent,
                "windowMinSeconds": Double(sizes.minimumFrames) / 16_000,
                "windowMaxSeconds": Double(sizes.maximumFrames) / 16_000,
                "audioSeconds": metrics.audioSeconds,
                "wallSeconds": metrics.wallSeconds,
                "preparationSeconds": metrics.preparationSeconds,
                "realTimeFactor": metrics.realTimeFactor ?? 0,
                "inferenceSeconds": metrics.inferenceSeconds,
                "windows": metrics.windows,
                "skippedSilentWindows": metrics.skippedSilentWindows,
                "lostIntervals": metrics.lostIntervals,
                "peakQueuedWindows": metrics.peakQueuedWindows,
                "peakFootprintMB": metrics.peakFootprintMegabytes,
                "maxResidentMB": maxResident,
                "rows": result.rows.count,
                "meetingID": result.meetingID.uuidString,
            ]
            if let out = value("--json-out"), let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
            if let out = value("--transcript-out") {
                try? result.rows.map(\.text).joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
            let summary = String(
                format: "audio %.0f s, wall %.0f s (model ready after %.0f s), RTF %.3f, windows %d (silent %d), lost intervals %d, peak footprint %.0f MB, peak resident %.0f MB, rows %d",
                metrics.audioSeconds, metrics.wallSeconds, metrics.preparationSeconds, metrics.realTimeFactor ?? 0, metrics.windows,
                metrics.skippedSilentWindows, metrics.lostIntervals, metrics.peakFootprintMegabytes, maxResident, result.rows.count
            )
            print(summary)
            return metrics.lostIntervals == 0 ? 0 : 3
        } catch {
            print("failed: \(error)")
            return 1
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    /// Stores the new value and returns the one it replaced.
    func exchange(_ new: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
#endif
