import CoreAudio
import Darwin
import Foundation

enum DebugMeetingUpdate: Sendable {
    case status(String)
    case rows([MeetingTranscriptRow])
    case metrics(String)
    case finished(partial: Bool)
}

/// Isolated manual test harness. It is never constructed by the live default.
actor DebugMeetingSession {
    private let permission = AVCaptureMicrophonePermissionService()
    private let engine = WhisperKitTranscriptionService(logsInference: false)
    private let system = SystemAudioCapture()
    private lazy var microphone = MeetingMicrophoneCapture(permission: permission)
    private let profile: LanguageProfile
    private let emit: @Sendable (DebugMeetingUpdate) -> Void
    private var stopRequested = false
    private var pauseRequested = false
    private var resumeRequested = false
    private var paused = false
    private var captureFinished = false
    private var partial = false
    private var worker: LongFormTranscriber?
    private var startedAt: TimeInterval = 0
    private var captureEndedAt: TimeInterval?

    init(profile: LanguageProfile, emit: @escaping @Sendable (DebugMeetingUpdate) -> Void) {
        self.profile = profile
        self.emit = emit
    }

    func start(processID: pid_t) async throws {
        emit(.status("Preparing the local speech model…"))
        let state = await engine.modelState(for: profile)
        guard state.isReady || state.canPrepareUnattended else { throw DebugMeetingError.modelUnavailable }
        if !state.isReady { try await engine.prepare(for: profile) }
        guard !stopRequested else { emit(.finished(partial: false)); return }
        guard permission.currentAuthorization == .authorized else { throw MeetingMicrophoneError.permissionUnavailable }
        emit(.status("Starting system audio and microphone…"))
        let origin = AudioGetCurrentHostTime()
        do {
            let systemBuffer = try system.start(processID: processID)
            await Task.yield()
            guard !stopRequested else {
                system.stop()
                emit(.finished(partial: false))
                return
            }
            let microphoneBuffer = try microphone.start(selection: .systemDefault)
            let systemProcessor = try SystemAudioChunkProcessor(buffer: systemBuffer, inputSampleRate: systemBuffer.sampleRate, originHostTime: origin)
            let microphoneProcessor = try SystemAudioChunkProcessor(buffer: microphoneBuffer, inputSampleRate: microphoneBuffer.sampleRate, originHostTime: origin, source: .microphone)
            let worker = LongFormTranscriber(engine: engine, profile: profile)
            self.worker = worker
            startedAt = ProcessInfo.processInfo.systemUptime
            emit(.status("Recording — local audio is kept in memory."))
            Task { await pump(systemProcessor, microphoneProcessor, systemBuffer, microphoneBuffer, worker) }
            Task { await transcribe(worker) }
        } catch {
            system.stop()
            microphone.stop()
            throw error
        }
    }

    func stop() {
        stopRequested = true
        emit(.status("Finishing the transcript…"))
    }

    func pause() {
        guard !stopRequested, !paused else { return }
        pauseRequested = true
        emit(.status("Pausing…"))
    }

    func resume() {
        guard !stopRequested, paused else { return }
        resumeRequested = true
        emit(.status("Resuming…"))
    }

    private func pump(_ systemProcessor: SystemAudioChunkProcessor, _ microphoneProcessor: SystemAudioChunkProcessor,
                      _ systemBuffer: MeetingAudioBuffer, _ microphoneBuffer: MeetingAudioBuffer,
                      _ worker: LongFormTranscriber) async {
        var systemWindows = MeetingWindowBuilder(source: .system)
        var microphoneWindows = MeetingWindowBuilder(source: .microphone)
        do {
            while true {
                if pauseRequested, !paused {
                    try system.pause()
                    try microphone.pause()
                    while let chunk = try systemProcessor.take() {
                        for window in try systemWindows.append(chunk) { try await worker.enqueue(window) }
                    }
                    while let chunk = try microphoneProcessor.take() {
                        for window in try microphoneWindows.append(chunk) { try await worker.enqueue(window) }
                    }
                    if let window = systemWindows.finish() { try await worker.enqueue(window) }
                    if let window = microphoneWindows.finish() { try await worker.enqueue(window) }
                    systemWindows = MeetingWindowBuilder(source: .system)
                    microphoneWindows = MeetingWindowBuilder(source: .microphone)
                    systemProcessor.prepareForResume()
                    microphoneProcessor.prepareForResume()
                    pauseRequested = false
                    paused = true
                    emit(.status("Paused — audio is not being captured."))
                }
                if resumeRequested, paused {
                    try system.resume()
                    try microphone.resume()
                    resumeRequested = false
                    paused = false
                    emit(.status("Recording — transcript stays on this Mac."))
                }
                if stopRequested {
                    if captureEndedAt == nil { captureEndedAt = ProcessInfo.processInfo.systemUptime }
                    system.stop(); microphone.stop()
                }
                if paused, !stopRequested {
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                while let chunk = try systemProcessor.take() {
                    for window in try systemWindows.append(chunk) { try await worker.enqueue(window) }
                }
                while let chunk = try microphoneProcessor.take() {
                    for window in try microphoneWindows.append(chunk) { try await worker.enqueue(window) }
                }
                let systemStats = systemBuffer.snapshot()
                let microphoneStats = microphoneBuffer.snapshot()
                let droppedCallbacks = systemStats.droppedCallbacks + microphoneStats.droppedCallbacks
                guard droppedCallbacks == 0 else {
                    await worker.recordLostIntervals(Int(droppedCallbacks))
                    throw LongFormTranscriptionError.missingAudio
                }
                if stopRequested {
                    for (processor, source) in [(systemProcessor, MeetingAudioSource.system), (microphoneProcessor, MeetingAudioSource.microphone)] {
                        let tail = try processor.finish()
                        let windows = try source == .system ? systemWindows.append(tail) : microphoneWindows.append(tail)
                        for window in windows { try await worker.enqueue(window) }
                    }
                    if let window = systemWindows.finish() { try await worker.enqueue(window) }
                    if let window = microphoneWindows.finish() { try await worker.enqueue(window) }
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            partial = true
            if await worker.metrics.lostIntervals == 0 {
                await worker.recordLostIntervals()
            }
            if captureEndedAt == nil { captureEndedAt = ProcessInfo.processInfo.systemUptime }
            system.stop()
            microphone.stop()
            emit(.status("Capture stopped early. The transcript is partial."))
        }
        captureFinished = true
    }

    private func transcribe(_ worker: LongFormTranscriber) async {
        while true {
            do {
                if try await worker.drainOne() {
                    emit(.rows(await worker.assembler.rows))
                    await emitMetrics(worker)
                } else if captureFinished { break }
                else { try await Task.sleep(for: .milliseconds(100)) }
            } catch {
                partial = true
                stopRequested = true
                if captureEndedAt == nil { captureEndedAt = ProcessInfo.processInfo.systemUptime }
                system.stop()
                microphone.stop()
                await worker.cancel()
                emit(.status("Transcription stopped. The transcript is partial."))
                while !captureFinished {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                break
            }
        }
        emit(.rows(await worker.assembler.rows))
        await emitMetrics(worker)
        emit(.finished(partial: partial))
    }
    private func emitMetrics(_ worker: LongFormTranscriber) async {
        let metrics = await worker.metrics
        let elapsed = max((captureEndedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt, 0.001)
        var usage = rusage()
        let resident = getrusage(RUSAGE_SELF, &usage) == 0 ? Double(usage.ru_maxrss) / 1_048_576 : 0
        let realTimeFactor = metrics.realTimeFactor.map { String(format: "%.2f", $0) } ?? "n/a"
        let text = String(
            format: "Audio RTF: %@; inference / meeting time: %.2f; peak queue: %d; max queue delay: %.1f s; peak process memory: %.0f MB; silent windows: %d; lost intervals: %d",
            realTimeFactor,
            metrics.inferenceSeconds / elapsed,
            metrics.peakQueuedWindows,
            metrics.maximumQueueDelay,
            resident,
            metrics.skippedSilentWindows,
            metrics.lostIntervals
        )
        emit(.metrics(text))
    }
}

enum DebugMeetingError: Error { case modelUnavailable }
