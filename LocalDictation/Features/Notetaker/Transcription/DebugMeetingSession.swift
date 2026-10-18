#if DEBUG
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

    private func pump(_ systemProcessor: SystemAudioChunkProcessor, _ microphoneProcessor: SystemAudioChunkProcessor,
                      _ systemBuffer: MeetingAudioBuffer, _ microphoneBuffer: MeetingAudioBuffer,
                      _ worker: LongFormTranscriber) async {
        var systemWindows = MeetingWindowBuilder(source: .system)
        var microphoneWindows = MeetingWindowBuilder(source: .microphone)
        var lastSystemCallbacks: Int64 = 0
        var lastMicrophoneCallbacks: Int64 = 0
        var lastHealthCheck = ProcessInfo.processInfo.systemUptime
        do {
            while true {
                if stopRequested {
                    if captureEndedAt == nil { captureEndedAt = ProcessInfo.processInfo.systemUptime }
                    system.stop(); microphone.stop()
                }
                while let chunk = try systemProcessor.take() {
                    for window in try systemWindows.append(chunk) { try await worker.enqueue(window) }
                }
                while let chunk = try microphoneProcessor.take() {
                    for window in try microphoneWindows.append(chunk) { try await worker.enqueue(window) }
                }
                let systemStats = systemBuffer.snapshot()
                let microphoneStats = microphoneBuffer.snapshot()
                guard systemStats.droppedCallbacks == 0, microphoneStats.droppedCallbacks == 0 else {
                    throw LongFormTranscriptionError.missingAudio
                }
                if ProcessInfo.processInfo.systemUptime - lastHealthCheck >= 5 {
                    guard systemStats.receivedCallbacks > lastSystemCallbacks,
                          microphoneStats.receivedCallbacks > lastMicrophoneCallbacks else {
                        throw LongFormTranscriptionError.missingAudio
                    }
                    lastSystemCallbacks = systemStats.receivedCallbacks
                    lastMicrophoneCallbacks = microphoneStats.receivedCallbacks
                    lastHealthCheck = ProcessInfo.processInfo.systemUptime
                }
                if stopRequested {
                    guard systemStats.receivedCallbacks > 0, microphoneStats.receivedCallbacks > 0 else {
                        throw LongFormTranscriptionError.missingAudio
                    }
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
                emit(.status("Transcription stopped. The transcript is partial."))
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
        let text = String(format: "Inference / meeting time: %.2f; peak queue: %d; max queue delay: %.1f s; peak process memory: %.0f MB", metrics.inferenceSeconds / elapsed, metrics.peakQueuedWindows, metrics.maximumQueueDelay, resident)
        emit(.metrics(text))
    }
}

enum DebugMeetingError: Error { case modelUnavailable }
#endif
