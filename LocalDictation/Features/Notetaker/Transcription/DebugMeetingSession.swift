import CoreAudio
import Darwin
import Foundation

enum DebugMeetingUpdate: Sendable {
    case status(String)
    case diarization(DiarizationDisplayState)
    case rows([MeetingTranscriptRow])
    case metrics(String)
    case finished(partial: Bool, persisted: Bool, issues: [MeetingPartialIssue])
}

enum MeetingPartialIssue: String, Sendable, Hashable, CaseIterable {
    case audioIntervalMissed
    case captureStopped
    case transcriptionStopped
    case localStorageFailed
}

/// Coordinates a live meeting while keeping capture and recognition independent.
actor DebugMeetingSession {
    private let permission = AVCaptureMicrophonePermissionService()
    private let engine: any TranscriptionService
    private let system = SystemAudioCapture()
    private lazy var microphone = MeetingMicrophoneCapture(permission: permission)
    private let profile: LanguageProfile
    private let title: String
    private let persistence: MeetingPersistenceRecorder
    private let diarizer: any StreamingSpeakerDiarizationService
    private let reviewer: (any MeetingSpeakerReviewing)?
    private let emit: @Sendable (DebugMeetingUpdate) -> Void
    private var stopRequested = false
    private var pauseRequested = false
    private var resumeRequested = false
    private var paused = false
    private var captureFinished = false
    private var partial = false
    private var storageFailed = false
    private var partialIssues: Set<MeetingPartialIssue> = []
    private var worker: LongFormTranscriber?
    private var startedAt: TimeInterval = 0
    private var captureEndedAt: TimeInterval?
    private var diarizationEnabled = false
    private var diarizationFailed = false
    private var timeline: LiveMeetingSpeakerTimeline
    private var reviewingSpeakers = false
    private var reviewBuffer = MeetingSpeakerReviewBuffer()
    private var reviewIdentities = MeetingSpeakerIdentityTracker()
    private var reviewTask: Task<Void, Never>?
    private var reviewCount = 0
    private var reviewSeconds: TimeInterval = 0
    private var echoRowsRemoved = 0

    init(
        profile: LanguageProfile,
        title: String,
        engine: any TranscriptionService,
        cleanup: MeetingTextCleanup = MeetingTextCleanup(),
        persistence: MeetingPersistenceRecorder = MeetingPersistenceRecorder(),
        diarizer: any StreamingSpeakerDiarizationService = ProductionDiarizationFactory.make(),
        reviewer: (any MeetingSpeakerReviewing)? = ProductionDiarizationFactory.makeReview(),
        emit: @escaping @Sendable (DebugMeetingUpdate) -> Void
    ) {
        self.profile = profile
        self.title = title
        self.engine = engine
        self.timeline = LiveMeetingSpeakerTimeline(cleanup: cleanup)
        self.persistence = persistence
        self.diarizer = diarizer
        self.reviewer = reviewer
        self.emit = emit
    }

    var meetingID: UUID? {
        get async { await persistence.meetingID }
    }

    func start(processID: pid_t) async throws {
        guard engine.supports(profile) else { throw TranscriptionError.unsupportedProfile(profile) }
        emit(.status("Preparing the local speech model…"))
        let state = await engine.modelState(for: profile)
        guard state.isReady || state.canPrepareUnattended else { throw DebugMeetingError.modelUnavailable }
        if !state.isReady { try await engine.prepare(for: profile) }
        guard !stopRequested else { emit(.finished(partial: false, persisted: false, issues: [])); return }
        emit(.status("Preparing local speaker separation…"))
        emit(.diarization(.preparing))
        do {
            if let reviewer, (try? await reviewer.prepare()) != nil {
                reviewingSpeakers = true
            } else {
                try await diarizer.prepare()
            }
            diarizationEnabled = true
            emit(.diarization(reviewingSpeakers ? .reviewing : .active))
        } catch {
            diarizationEnabled = false
            emit(.diarization(.fallback))
        }
        guard !stopRequested else { emit(.finished(partial: false, persisted: false, issues: [])); return }
        guard permission.currentAuthorization == .authorized else { throw MeetingMicrophoneError.permissionUnavailable }
        try await persistence.begin(title: title, profile: profile)
        emit(.status("Starting system audio and microphone…"))
        let origin = AudioGetCurrentHostTime()
        do {
            let systemBuffer = try system.start(processID: processID)
            await Task.yield()
            guard !stopRequested else {
                system.stop()
                await persistence.discardEmptyMeeting()
                emit(.finished(partial: false, persisted: false, issues: []))
                return
            }
            let microphoneBuffer = try microphone.start(selection: .systemDefault)
            let voiceProcessing = microphone.usesVoiceProcessing ? "on" : "off"
            Log.audio.notice("Meeting microphone voice processing: \(voiceProcessing, privacy: .public)")
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
            await persistence.discardEmptyMeeting()
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
        var reportedDroppedCallbacks: Int64 = 0
        var warnedAboutAudioLoss = false
        do {
            while true {
                if pauseRequested, !paused {
                    try system.pause()
                    try microphone.pause()
                    while let chunk = try systemProcessor.take() {
                        await ingestDiarization(chunk)
                        await worker.recordSystemAudio(chunk)
                        for window in try systemWindows.append(chunk) { try await worker.enqueue(window) }
                    }
                    while let chunk = try microphoneProcessor.take() {
                        for window in try microphoneWindows.append(chunk) { try await worker.enqueue(window) }
                    }
                    scheduleSpeakerReview(final: true)
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
                    await ingestDiarization(chunk)
                    await worker.recordSystemAudio(chunk)
                    for window in try systemWindows.append(chunk) { try await worker.enqueue(window) }
                }
                while let chunk = try microphoneProcessor.take() {
                    for window in try microphoneWindows.append(chunk) { try await worker.enqueue(window) }
                }
                let systemStats = systemBuffer.snapshot()
                let microphoneStats = microphoneBuffer.snapshot()
                let droppedCallbacks = systemStats.droppedCallbacks + microphoneStats.droppedCallbacks
                if droppedCallbacks > reportedDroppedCallbacks {
                    await worker.recordLostIntervals(Int(droppedCallbacks - reportedDroppedCallbacks))
                    reportedDroppedCallbacks = droppedCallbacks
                    partial = true
                    partialIssues.insert(.audioIntervalMissed)
                    if !warnedAboutAudioLoss {
                        warnedAboutAudioLoss = true
                        emit(.status("Recording — a short audio interval was missed; capture is continuing."))
                    }
                }
                if stopRequested {
                    for (processor, source) in [(systemProcessor, MeetingAudioSource.system), (microphoneProcessor, MeetingAudioSource.microphone)] {
                        let tail = try processor.finish()
                        if source == .system {
                            await ingestDiarization(tail)
                            await worker.recordSystemAudio(tail)
                        }
                        let windows = try source == .system ? systemWindows.append(tail) : microphoneWindows.append(tail)
                        for window in windows { try await worker.enqueue(window) }
                    }
                    await finishDiarization()
                    if let window = systemWindows.finish() { try await worker.enqueue(window) }
                    if let window = microphoneWindows.finish() { try await worker.enqueue(window) }
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            let category = meetingPipelineFailureCategory(error)
            Log.audio.error("Meeting capture stopped early: \(category, privacy: .public)")
            partial = true
            partialIssues.insert(.captureStopped)
            if await worker.metrics.lostIntervals == 0 {
                await worker.recordLostIntervals()
            }
            if captureEndedAt == nil { captureEndedAt = ProcessInfo.processInfo.systemUptime }
            system.stop()
            microphone.stop()
            await finishDiarization()
            if let window = systemWindows.finish() { try? await worker.enqueue(window) }
            if let window = microphoneWindows.finish() { try? await worker.enqueue(window) }
            emit(.status("Capture stopped early. The transcript is partial."))
        }
        captureFinished = true
    }

    private func transcribe(_ worker: LongFormTranscriber) async {
        while true {
            do {
                if try await worker.drainOne() {
                    let baseRows = await worker.assembler.rows
                    timeline.updateTranscript(baseRows)
                    publishTranscript()
                    // Persist stable recognition windows so late splits never
                    // duplicate or discard text if the process is interrupted.
                    do {
                        try await persistence.persist(rows: baseRows)
                    } catch {
                        storageFailed = true
                        partial = true
                        partialIssues.insert(.localStorageFailed)
                        stopRequested = true
                        if captureEndedAt == nil { captureEndedAt = ProcessInfo.processInfo.systemUptime }
                        system.stop()
                        microphone.stop()
                        emit(.status("Local storage failed. Capture stopped; the visible transcript remains in memory."))
                        while !captureFinished {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        break
                    }
                    await emitMetrics(worker)
                } else if captureFinished { break }
                else { try await Task.sleep(for: .milliseconds(100)) }
            } catch {
                let category = meetingPipelineFailureCategory(error)
                Log.transcription.error("Meeting transcription stopped early: \(category, privacy: .public)")
                partial = true
                partialIssues.insert(.transcriptionStopped)
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
        let baseRows = await worker.assembler.rows
        timeline.updateTranscript(baseRows)
        let finalRows = withoutEcho(timeline.rows)
        emit(.rows(finalRows))
        await emitMetrics(worker)
        do {
            if !storageFailed {
                try await persistence.replace(rows: finalRows)
            }
            let orderedIssues = MeetingPartialIssue.allCases.filter(partialIssues.contains)
            try await persistence.finish(partial: partial, issueCodes: orderedIssues.map(\.rawValue))
        } catch {
            storageFailed = true
            partial = true
            partialIssues.insert(.localStorageFailed)
            emit(.status("The transcript remains in memory because the meeting could not be finalized on disk."))
        }
        let orderedIssues = MeetingPartialIssue.allCases.filter(partialIssues.contains)
        emit(.finished(partial: partial, persisted: !storageFailed, issues: orderedIssues))
    }

    private func withoutEcho(_ rows: [MeetingTranscriptRow]) -> [MeetingTranscriptRow] {
        let filtered = MeetingEchoFilter.removingEcho(from: rows)
        echoRowsRemoved = filtered.removed
        return filtered.rows
    }

    private func ingestDiarization(_ chunk: MeetingAudioChunk) async {
        guard diarizationEnabled, !diarizationFailed, !chunk.samples.isEmpty else { return }
        if reviewingSpeakers {
            reviewBuffer.append(chunk)
            scheduleSpeakerReview()
            return
        }
        do {
            applyDiarization(SpeakerTimelineUpdate(turns: try await diarizer.ingest(chunk)))
        } catch {
            diarizationFailed = true
            diarizationEnabled = false
            timeline.clearAttribution()
            publishTranscript()
            emit(.diarization(.failed))
        }
    }

    private func finishDiarization() async {
        if reviewingSpeakers {
            await reviewTask?.value
            scheduleSpeakerReview(final: true)
            await reviewTask?.value
            reviewBuffer = MeetingSpeakerReviewBuffer()
            reviewIdentities = MeetingSpeakerIdentityTracker()
            return
        }
        guard diarizationEnabled, !diarizationFailed else { return }
        do {
            applyDiarization(SpeakerTimelineUpdate(turns: try await diarizer.finish()))
        } catch {
            diarizationFailed = true
            diarizationEnabled = false
            timeline.clearAttribution()
            publishTranscript()
            emit(.diarization(.failed))
        }
    }

    private func scheduleSpeakerReview(final: Bool = false) {
        guard reviewingSpeakers, !diarizationFailed, reviewTask == nil, let reviewer,
              let window = reviewBuffer.takeWindow(final: final) else { return }
        reviewTask = Task(priority: .utility) {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await reviewer.review(window)
                if let update = reviewIdentities.update(result, window: window) {
                    applyDiarization(update)
                }
                reviewCount += 1
                reviewSeconds += ProcessInfo.processInfo.systemUptime - start
            } catch {
                diarizationFailed = true
                diarizationEnabled = false
                reviewBuffer = MeetingSpeakerReviewBuffer()
                reviewIdentities = MeetingSpeakerIdentityTracker()
                Log.audio.error("Local speaker review stopped; later passages use source labels.")
                emit(.diarization(.failed))
            }
            reviewTask = nil
            if paused, !stopRequested { scheduleSpeakerReview(final: true) }
        }
    }

    private func applyDiarization(_ update: SpeakerTimelineUpdate) {
        guard update.affectedFrames != nil else { return }
        let previous = timeline.rows
        timeline.apply(update)
        if timeline.rows != previous { publishTranscript() }
    }

    private func publishTranscript() {
        emit(.rows(withoutEcho(timeline.rows)))
    }

    private func emitMetrics(_ worker: LongFormTranscriber) async {
        let metrics = await worker.metrics
        let diarizationMetrics = await diarizer.metricsSnapshot()
        let elapsed = max((captureEndedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt, 0.001)
        var usage = rusage()
        let resident = getrusage(RUSAGE_SELF, &usage) == 0 ? Double(usage.ru_maxrss) / 1_048_576 : 0
        let realTimeFactor = metrics.realTimeFactor.map { String(format: "%.2f", $0) } ?? "n/a"
        let diarizationRTF = diarizationMetrics.realTimeFactor.map { String(format: "%.3f", $0) } ?? "n/a"
        let text = String(
            format: "ASR RTF: %@; inference / meeting time: %.2f; diarization RTF: %@; diarization load: %.2f s; speaker turns: %d; diarization discontinuities: %d; speaker review windows: %d (%.2f s); peak queue: %d; max queue delay: %.1f s; peak process memory: %.0f MB; silent windows: %d; lost intervals: %d; echo rows removed: %d",
            realTimeFactor,
            metrics.inferenceSeconds / elapsed,
            diarizationRTF,
            diarizationMetrics.modelLoadSeconds,
            diarizationMetrics.emittedTurns,
            diarizationMetrics.discontinuities,
            reviewCount,
            reviewSeconds,
            metrics.peakQueuedWindows,
            metrics.maximumQueueDelay,
            resident,
            metrics.skippedSilentWindows,
            metrics.lostIntervals,
            echoRowsRemoved
        )
        emit(.metrics(text))
    }
}

enum DebugMeetingError: Error { case modelUnavailable }

private func meetingPipelineFailureCategory(_ error: Error) -> String {
    switch error {
    case let failure as SystemAudioCaptureError:
        switch failure {
        case .processNotFound: "system_audio_process_not_found"
        case .unsupportedFormat: "system_audio_unsupported_format"
        case .invalidState: "system_audio_invalid_state"
        case .discontinuity: "system_audio_discontinuity"
        case let .coreAudio(status): "system_audio_core_audio_\(status)"
        }
    case let failure as LongFormTranscriptionError:
        switch failure {
        case .invalidFormat: "transcription_invalid_format"
        case .backlogFull: "transcription_backlog_full"
        case .alreadyProcessing: "transcription_already_processing"
        case .modelNotReady: "transcription_model_not_ready"
        case .cancelled: "transcription_cancelled"
        }
    default:
        String(reflecting: type(of: error))
    }
}
