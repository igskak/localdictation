import Darwin
import Foundation

/// Window sizes in 16 kHz frames. Whole multiples of the builder's 20 ms
/// energy frame, and every maximum stays inside Whisper's thirty seconds.
struct FileWindowSizes: Sendable, Equatable {
    let minimumFrames: Int
    let maximumFrames: Int
    let pauseFrames: Int

    /// What a live meeting uses: a first result after eight seconds.
    static let live = FileWindowSizes(minimumFrames: 128_000, maximumFrames: 320_000, pauseFrames: 4_800)
    /// A file needs no early first result, so windows are longer: more context
    /// for the model and fewer decode calls.
    static let file = FileWindowSizes(minimumFrames: 240_000, maximumFrames: 448_000, pauseFrames: 4_800)
}

struct FileTranscriptionProgress: Sendable, Equatable {
    let processedFrames: Int64
    let totalFrames: Int64
    let elapsed: TimeInterval
    /// Nil until enough audio has been recognised to extrapolate from.
    let remaining: TimeInterval?

    var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(max(Double(processedFrames) / Double(totalFrames), 0), 1)
    }
}

struct FileTranscriptionMetrics: Sendable, Equatable {
    var audioSeconds: Double = 0
    /// Wall time of the whole run, model preparation included.
    var wallSeconds: Double = 0
    /// Loading the model before the first window. A cold Core ML compile can
    /// take many minutes, and it is not what a long file costs per second.
    var preparationSeconds: Double = 0
    var inferenceSeconds: Double = 0
    var windows: Int = 0
    var skippedSilentWindows: Int = 0
    var lostIntervals: Int = 0
    var peakQueuedWindows: Int = 0
    var peakFootprintMegabytes: Double = 0

    /// Recognition time per second of audio, preparation excluded; below 1 is
    /// faster than the recording.
    var realTimeFactor: Double? { audioSeconds > 0 ? max(wallSeconds - preparationSeconds, 0) / audioSeconds : nil }
}

/// Why a run ended without a note. Content-free: safe for the local log and,
/// as a case, for the enumerated failure event in F4.
enum FileTranscriptionFailure: Error, Equatable, Sendable {
    case file(AudioFileError)
    case modelUnavailable
    case unsupportedLanguage
    case noSpeech
    case recognitionStopped
    case storageFailed
    case cancelled
    /// Refused before anything ran.
    case unsupportedType
    case busy
}

struct FileTranscriptionResult: Sendable {
    let meetingID: UUID
    let rows: [MeetingTranscriptRow]
    let metrics: FileTranscriptionMetrics
}

/// Transcribes one complete audio source faster than real time.
///
/// The live meeting path records a lost interval when its queue is full,
/// because a microphone cannot wait. A file can: the reader pauses until the
/// transcriber has caught up, so no interval of a file is ever dropped. The
/// note is written once, at the end. A cancelled or failed run therefore
/// leaves nothing behind.
actor FileTranscriptionSession {
    private let source: any AudioFileReading
    private let engine: any TranscriptionService
    private let profile: LanguageProfile
    private let persistence: MeetingPersistenceRecorder
    private let title: String
    private let originalFile: URL?
    private let sizes: FileWindowSizes
    private let queueCapacity: Int
    private let uptime: @Sendable () -> TimeInterval
    private let footprint: @Sendable () -> Double
    private let emit: @Sendable (FileTranscriptionProgress) -> Void
    private var worker: LongFormTranscriber?
    private var cancelRequested = false
    private var running = false

    init(
        source: any AudioFileReading,
        engine: any TranscriptionService,
        profile: LanguageProfile,
        persistence: MeetingPersistenceRecorder = MeetingPersistenceRecorder(),
        title: String,
        originalFile: URL? = nil,
        sizes: FileWindowSizes = .file,
        queueCapacity: Int = 8,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        footprint: @escaping @Sendable () -> Double = { ProcessMemory.footprintMegabytes() },
        emit: @escaping @Sendable (FileTranscriptionProgress) -> Void = { _ in }
    ) {
        self.source = source
        self.engine = engine
        self.profile = profile
        self.persistence = persistence
        self.title = title
        self.originalFile = originalFile
        self.sizes = sizes
        self.queueCapacity = queueCapacity
        self.uptime = uptime
        self.footprint = footprint
        self.emit = emit
    }

    /// Stops the run at the next suspension point and discards everything.
    /// The task that called `run()` should be cancelled as well, which also
    /// interrupts a recognition call already in flight.
    func cancel() async {
        cancelRequested = true
        await worker?.cancel()
    }

    func run() async throws -> FileTranscriptionResult {
        precondition(!running, "A session transcribes one file")
        running = true
        defer { source.close() }
        let started = uptime()
        var peak = footprint()

        guard engine.supports(profile) else { throw FileTranscriptionFailure.unsupportedLanguage }
        let state = await engine.modelState(for: profile)
        // A model that is already preparing (launch started it) or that failed
        // once is joined or retried: the engine coalesces concurrent calls.
        // Only a model that needs the person's approval to download is refused.
        guard state.isReady || state.isPreparing || state.canPrepareUnattended || isFailed(state) else {
            throw FileTranscriptionFailure.modelUnavailable
        }
        if !state.isReady {
            do { try await engine.prepare(for: profile) }
            catch {
                try checkCancelled()
                throw FileTranscriptionFailure.modelUnavailable
            }
        }
        try checkCancelled()

        let info: AudioFileInfo
        do {
            info = try await source.open()
        } catch let error as AudioFileError {
            throw FileTranscriptionFailure.file(error)
        } catch {
            throw FileTranscriptionFailure.file(.unreadable)
        }
        let preparedAt = uptime()
        let worker = LongFormTranscriber(engine: engine, profile: profile, capacity: queueCapacity)
        self.worker = worker
        var windows = MeetingWindowBuilder(
            source: .system,
            minimumFrames: sizes.minimumFrames,
            maximumFrames: sizes.maximumFrames,
            pauseFrames: sizes.pauseFrames
        )
        var windowCount = 0
        var decodedFrames: Int64 = 0

        do {
            while let chunk = try readChunk() {
                try checkCancelled()
                decodedFrames = chunk.startFrame + Int64(chunk.samples.count)
                let ready = try windows.append(chunk)
                for window in ready {
                    windowCount += 1
                    try await enqueueWaiting(window, worker: worker)
                }
                if let last = ready.last {
                    try await drain(worker, through: last.endFrame, total: max(info.estimatedFrames, decodedFrames),
                                    started: started, preparedAt: preparedAt, peak: &peak)
                }
            }
            if let tail = windows.finish() {
                windowCount += 1
                try await enqueueWaiting(tail, worker: worker)
                try await drain(worker, through: tail.endFrame, total: decodedFrames,
                                started: started, preparedAt: preparedAt, peak: &peak)
            }
        } catch let failure as FileTranscriptionFailure {
            throw failure
        } catch let error as AudioFileError {
            throw FileTranscriptionFailure.file(error)
        } catch let error as LongFormTranscriptionError where error == .cancelled {
            throw FileTranscriptionFailure.cancelled
        } catch is CancellationError {
            throw FileTranscriptionFailure.cancelled
        } catch {
            Log.transcription.error("File transcription stopped: \(String(reflecting: type(of: error)), privacy: .public)")
            throw FileTranscriptionFailure.recognitionStopped
        }
        try checkCancelled()

        let baseRows = await worker.assembler.rows
        let rows = SentenceRowSplitter().split(baseRows)
        guard !rows.isEmpty else { throw FileTranscriptionFailure.noSpeech }
        let longForm = await worker.metrics
        var metrics = FileTranscriptionMetrics()
        metrics.audioSeconds = Double(decodedFrames) / AudioFileSourceFormat.sampleRate
        metrics.wallSeconds = uptime() - started
        metrics.preparationSeconds = preparedAt - started
        metrics.inferenceSeconds = longForm.inferenceSeconds
        metrics.windows = windowCount
        metrics.skippedSilentWindows = longForm.skippedSilentWindows
        metrics.lostIntervals = longForm.lostIntervals
        metrics.peakQueuedWindows = longForm.peakQueuedWindows
        metrics.peakFootprintMegabytes = max(peak, footprint())

        let meetingID: UUID
        do {
            meetingID = try await persistence.saveFile(
                title: title,
                profile: profile,
                source: originalFile.map {
                    MeetingSourceFile(name: $0.lastPathComponent, path: $0.path, durationSeconds: metrics.audioSeconds)
                },
                rows: rows
            )
        } catch is CancellationError {
            throw FileTranscriptionFailure.cancelled
        } catch {
            throw FileTranscriptionFailure.storageFailed
        }
        return FileTranscriptionResult(meetingID: meetingID, rows: rows, metrics: metrics)
    }

    private func isFailed(_ state: TranscriptionModelState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Internals

    private func readChunk() throws -> MeetingAudioChunk? {
        try source.nextChunk()
    }

    private func checkCancelled() throws {
        if cancelRequested || Task.isCancelled { throw FileTranscriptionFailure.cancelled }
    }

    /// Enqueues, and when the transcriber is full lets it finish a window
    /// first. Nothing is dropped and nothing waits for longer than one decode.
    func enqueueWaiting(_ window: MeetingRecognitionAudio, worker: LongFormTranscriber) async throws {
        while true {
            do {
                try await worker.enqueue(window)
                return
            } catch LongFormTranscriptionError.backlogFull {
                try checkCancelled()
                _ = try await worker.drainOne()
            }
        }
    }

    private func drain(
        _ worker: LongFormTranscriber,
        through processedFrames: Int64,
        total: Int64,
        started: TimeInterval,
        preparedAt: TimeInterval,
        peak: inout Double
    ) async throws {
        while await worker.queuedCount() > 0 {
            try checkCancelled()
            _ = try await worker.drainOne()
            peak = max(peak, footprint())
        }
        let now = uptime()
        emit(FileTranscriptionProgress(
            processedFrames: processedFrames,
            totalFrames: total,
            elapsed: now - started,
            remaining: Self.remaining(elapsed: now - preparedAt, processedFrames: processedFrames, totalFrames: total)
        ))
    }

    /// Uses the rate after model preparation, including the time to read and
    /// skip quiet sections. Progress counts those sections as processed.
    static func remaining(elapsed: TimeInterval, processedFrames: Int64, totalFrames: Int64) -> TimeInterval? {
        let processedSeconds = Double(processedFrames) / AudioFileSourceFormat.sampleRate
        guard processedSeconds >= 30, elapsed > 0 else { return nil }
        let leftSeconds = max(Double(totalFrames - processedFrames) / AudioFileSourceFormat.sampleRate, 0)
        return leftSeconds * (elapsed / processedSeconds)
    }
}

enum ProcessMemory {
    /// The footprint Activity Monitor reports as "Memory", in megabytes.
    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
