import AppKit
import Foundation

struct MeetingApplicationSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let localizedName: String
    let bundleIdentifier: String?
    let isProducingOutput: Bool
}

protocol MeetingApplicationDetecting: Sendable {
    func candidate(for snapshot: MeetingApplicationSnapshot) -> MeetingCandidate?
}

/// Zoom can be identified from its local application identity. No window title,
/// meeting title, URL, or participant information is inspected.
struct ZoomMeetingDetectionAdapter: MeetingApplicationDetecting {
    func candidate(for snapshot: MeetingApplicationSnapshot) -> MeetingCandidate? {
        let name = snapshot.localizedName.lowercased()
        let bundle = snapshot.bundleIdentifier?.lowercased()
        let isZoom = bundle == "us.zoom.xos"
            || bundle?.hasPrefix("us.zoom.") == true
            || name == "zoom.us"
            || name.hasPrefix("zoom ")
        guard snapshot.isProducingOutput, isZoom else { return nil }
        return MeetingCandidate(
            platform: .zoom,
            processIdentifier: snapshot.processIdentifier,
            confidence: .confirmed
        )
    }
}

/// Core Audio identifies a Chrome process, not the active tab. Treating this as
/// a possible Meet call avoids reading browser titles or URLs and keeps the
/// adapter permission-free, but intentionally limits its confidence.
struct ChromeMeetDetectionAdapter: MeetingApplicationDetecting {
    func candidate(for snapshot: MeetingApplicationSnapshot) -> MeetingCandidate? {
        let name = snapshot.localizedName.lowercased()
        let isChrome = snapshot.bundleIdentifier?.lowercased().hasPrefix("com.google.chrome") == true
            || name == "google chrome"
            || name.hasPrefix("google chrome helper")
        guard snapshot.isProducingOutput, isChrome else { return nil }
        return MeetingCandidate(
            platform: .googleMeet,
            processIdentifier: snapshot.processIdentifier,
            confidence: .probable
        )
    }
}

struct MeetingCandidateDetector: Sendable {
    private let zoom = ZoomMeetingDetectionAdapter()
    private let meet = ChromeMeetDetectionAdapter()

    func candidate(in snapshots: [MeetingApplicationSnapshot]) -> MeetingCandidate? {
        let candidates = snapshots.flatMap { snapshot in
            [zoom.candidate(for: snapshot), meet.candidate(for: snapshot)].compactMap { $0 }
        }
        return candidates.sorted(by: precedes).first
    }

    func candidate(for option: MeetingProcessOption) -> MeetingCandidate? {
        // A manual start can target an open meeting app before it begins
        // producing output. Classification still stays local and identity-only.
        candidate(in: [MeetingApplicationSnapshot(
            processIdentifier: option.processID,
            localizedName: option.name,
            bundleIdentifier: option.bundleIdentifier,
            isProducingOutput: true
        )])
    }

    private func precedes(_ lhs: MeetingCandidate, _ rhs: MeetingCandidate) -> Bool {
        if lhs.confidence != rhs.confidence { return rank(lhs.confidence) > rank(rhs.confidence) }
        if lhs.platform != rhs.platform { return lhs.platform.rawValue < rhs.platform.rawValue }
        return (lhs.processIdentifier ?? 0) < (rhs.processIdentifier ?? 0)
    }

    private func rank(_ confidence: DetectionConfidence) -> Int {
        switch confidence {
        case .possible: 1
        case .probable: 2
        case .confirmed: 3
        }
    }
}

private struct MeetingCandidateKey: Sendable, Hashable {
    let platform: MeetingPlatform
    let processIdentifier: pid_t?

    init(_ candidate: MeetingCandidate) {
        platform = candidate.platform
        processIdentifier = candidate.processIdentifier
    }
}

/// Pure suppression policy: one card for one uninterrupted candidate, plus a
/// per-platform cooldown after dismissal so helper-process churn cannot spam.
struct MeetingSuggestionPolicy: Sendable, Equatable {
    let cooldown: TimeInterval
    private(set) var visibleCandidate: MeetingCandidate?
    private var observedKey: MeetingCandidateKey?
    private var dismissedAt: [MeetingPlatform: TimeInterval] = [:]

    init(cooldown: TimeInterval = 15 * 60) {
        self.cooldown = cooldown
    }

    @discardableResult
    mutating func observe(_ candidate: MeetingCandidate?, at now: TimeInterval) -> MeetingCandidate? {
        guard let candidate else {
            observedKey = nil
            visibleCandidate = nil
            return nil
        }
        let key = MeetingCandidateKey(candidate)
        guard key != observedKey else { return visibleCandidate }
        observedKey = key
        if let lastDismissal = dismissedAt[candidate.platform], now - lastDismissal < cooldown {
            visibleCandidate = nil
        } else {
            visibleCandidate = candidate
        }
        return visibleCandidate
    }

    mutating func dismiss(at now: TimeInterval) -> MeetingCandidate? {
        guard let candidate = visibleCandidate else { return nil }
        dismissedAt[candidate.platform] = now
        visibleCandidate = nil
        return candidate
    }

    mutating func accept() -> MeetingCandidate? {
        defer { visibleCandidate = nil }
        return visibleCandidate
    }

    mutating func reset() {
        visibleCandidate = nil
        observedKey = nil
    }
}

enum CallEndGuardAction: Sendable, Equatable {
    case none
    case beganGrace
    case cancelledGrace
    case pauseSameNote
    case resumeSameNote
}

enum CallEndGuardState: Sendable, Equatable {
    case monitoring
    case grace(deadline: TimeInterval)
    case pausedSameNote
    case ignoredForSession
}

/// Pure call-end policy. Expiry pauses capture instead of finalizing the note,
/// which is what makes a false stop recoverable without creating a new note.
struct CallEndGuard: Sendable, Equatable {
    let gracePeriod: TimeInterval
    private(set) var state: CallEndGuardState = .monitoring

    init(gracePeriod: TimeInterval = 30) {
        self.gracePeriod = gracePeriod
    }

    mutating func observe(signalPresent: Bool, at now: TimeInterval) -> CallEndGuardAction {
        switch (state, signalPresent) {
        case (.monitoring, true), (.ignoredForSession, _):
            return .none
        case (.monitoring, false):
            state = .grace(deadline: now + gracePeriod)
            return .beganGrace
        case (.grace, true):
            state = .monitoring
            return .cancelledGrace
        case let (.grace(deadline), false) where now >= deadline:
            state = .pausedSameNote
            return .pauseSameNote
        case (.grace, false), (.pausedSameNote, false):
            return .none
        case (.pausedSameNote, true):
            state = .monitoring
            return .resumeSameNote
        }
    }

    mutating func keepRecording() -> CallEndGuardAction {
        let action: CallEndGuardAction = state == .pausedSameNote ? .resumeSameNote : .cancelledGrace
        state = .ignoredForSession
        return action
    }

    func secondsRemaining(at now: TimeInterval) -> Int? {
        guard case let .grace(deadline) = state else { return nil }
        return max(Int(ceil(deadline - now)), 0)
    }
}

enum MeetingDetectionEvaluation: String, Codable, Sendable {
    case truePositive
    case falsePositive
    case falseNegative
}

struct MeetingDetectionCounts: Codable, Sendable, Equatable {
    var truePositives = 0
    var falsePositives = 0
    var falseNegatives = 0
    private(set) var falsePositiveRate: Double?
    private(set) var falseNegativeRate: Double?

    mutating func record(_ evaluation: MeetingDetectionEvaluation) {
        switch evaluation {
        case .truePositive: truePositives += 1
        case .falsePositive: falsePositives += 1
        case .falseNegative: falseNegatives += 1
        }
        let positiveDenominator = truePositives + falsePositives
        falsePositiveRate = positiveDenominator == 0
            ? nil : Double(falsePositives) / Double(positiveDenominator)
        let negativeDenominator = truePositives + falseNegatives
        falseNegativeRate = negativeDenominator == 0
            ? nil : Double(falseNegatives) / Double(negativeDenominator)
    }
}

struct MeetingDetectionMetrics: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    var zoom: MeetingDetectionCounts
    var googleMeet: MeetingDetectionCounts

    init(zoom: MeetingDetectionCounts = .init(), googleMeet: MeetingDetectionCounts = .init()) {
        schemaVersion = Self.currentSchemaVersion
        self.zoom = zoom
        self.googleMeet = googleMeet
    }

    mutating func record(_ evaluation: MeetingDetectionEvaluation, platform: MeetingPlatform) {
        switch platform {
        case .zoom: zoom.record(evaluation)
        case .googleMeet: googleMeet.record(evaluation)
        case .manual: break
        }
    }
}

/// Dogfood-only, local evaluation data. The file contains closed counters only;
/// it never contains app identities, PIDs, titles, URLs, participants, or text.
actor LocalMeetingDetectionMetricsRecorder {
    private let url: URL
    private let fileManager: FileManager
    private var metrics: MeetingDetectionMetrics

    init(
        url: URL = ApplicationSupportDirectory.file("notetaker-detection-metrics.json"),
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(MeetingDetectionMetrics.self, from: data),
           decoded.schemaVersion == MeetingDetectionMetrics.currentSchemaVersion {
            metrics = decoded
        } else {
            metrics = MeetingDetectionMetrics()
        }
    }

    func record(_ evaluation: MeetingDetectionEvaluation, platform: MeetingPlatform) {
        metrics.record(evaluation, platform: platform)
        guard platform != .manual else { return }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(metrics).write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Diagnostics must never interfere with recording and stay silent.
        }
    }

    func snapshot() -> MeetingDetectionMetrics { metrics }
}

@MainActor
final class MeetingDetectionCoordinator {
    typealias SuggestionHandler = (MeetingCandidate?) -> Void

    private weak var model: DebugMeetingModel?
    private let resolver: any MeetingProcessResolving
    private let detector: MeetingCandidateDetector
    private let metrics: LocalMeetingDetectionMetricsRecorder
    private let onSuggestion: SuggestionHandler
    private var pollingTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var suggestionPolicy: MeetingSuggestionPolicy
    private var callEndGuard = CallEndGuard()
    private var activeCandidate: MeetingCandidate?
    private var latestCandidate: MeetingCandidate?
    private var acceptedCandidate: MeetingCandidate?

    init(
        model: DebugMeetingModel,
        resolver: any MeetingProcessResolving = CoreAudioMeetingProcessResolver(),
        detector: MeetingCandidateDetector = MeetingCandidateDetector(),
        metrics: LocalMeetingDetectionMetricsRecorder = LocalMeetingDetectionMetricsRecorder(),
        suggestionPolicy: MeetingSuggestionPolicy = MeetingSuggestionPolicy(),
        onSuggestion: @escaping SuggestionHandler
    ) {
        self.model = model
        self.resolver = resolver
        self.detector = detector
        self.metrics = metrics
        self.suggestionPolicy = suggestionPolicy
        self.onSuggestion = onSuggestion
    }

    func activate() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func deactivate() {
        pollingTask?.cancel()
        pollingTask = nil
        graceTask?.cancel()
        graceTask = nil
        suggestionPolicy.reset()
        activeCandidate = nil
        latestCandidate = nil
        acceptedCandidate = nil
        callEndGuard = CallEndGuard()
        model?.clearCallEndNotice()
        onSuggestion(nil)
    }

    func acceptSuggestion() -> MeetingCandidate? {
        acceptedCandidate = suggestionPolicy.accept()
        onSuggestion(nil)
        return acceptedCandidate
    }

    func dismissSuggestion() {
        guard let candidate = suggestionPolicy.dismiss(at: ProcessInfo.processInfo.systemUptime) else { return }
        onSuggestion(nil)
        Task { await metrics.record(.falsePositive, platform: candidate.platform) }
    }

    func recordingStarted(candidate: MeetingCandidate) {
        activeCandidate = candidate
        callEndGuard = CallEndGuard()
        graceTask?.cancel()
        suggestionPolicy.reset()
        onSuggestion(nil)
        let evaluation: MeetingDetectionEvaluation
        if acceptedCandidate == candidate || latestCandidate == candidate {
            evaluation = .truePositive
        } else {
            evaluation = .falseNegative
        }
        acceptedCandidate = nil
        Task { await metrics.record(evaluation, platform: candidate.platform) }
    }

    func recordingFinished() {
        activeCandidate = nil
        acceptedCandidate = nil
        graceTask?.cancel()
        graceTask = nil
        callEndGuard = CallEndGuard()
        model?.clearCallEndNotice()
    }

    func keepRecording() {
        graceTask?.cancel()
        graceTask = nil
        handle(callEndGuard.keepRecording())
        model?.clearCallEndNotice()
    }

    private func poll() async {
        let resolver = self.resolver
        guard let audioProcesses = try? await Task.detached(priority: .utility, operation: {
            try resolver.processes()
        }).value else { return }
        guard !Task.isCancelled else { return }
        let snapshots = audioProcesses.map { process in
            let application = NSRunningApplication(processIdentifier: process.processID)
            return MeetingApplicationSnapshot(
                processIdentifier: process.processID,
                localizedName: application?.localizedName ?? "",
                bundleIdentifier: application?.bundleIdentifier,
                isProducingOutput: process.isProducingOutput
            )
        }
        latestCandidate = detector.candidate(in: snapshots)

        if let activeCandidate {
            let signalPresent = snapshots.contains {
                $0.processIdentifier == activeCandidate.processIdentifier && $0.isProducingOutput
            }
            guard model?.paused != true || model?.autoPausedByCallEnd == true else { return }
            handle(callEndGuard.observe(
                signalPresent: signalPresent,
                at: ProcessInfo.processInfo.systemUptime
            ))
            return
        }

        let before = suggestionPolicy.visibleCandidate
        let after = suggestionPolicy.observe(latestCandidate, at: ProcessInfo.processInfo.systemUptime)
        if before != after { onSuggestion(after) }
    }

    private func handle(_ action: CallEndGuardAction) {
        switch action {
        case .none:
            if let remaining = callEndGuard.secondsRemaining(at: ProcessInfo.processInfo.systemUptime) {
                model?.showCallEndGrace(secondsRemaining: remaining)
            }
        case .beganGrace:
            scheduleGraceExpiry()
            model?.showCallEndGrace(secondsRemaining: Int(callEndGuard.gracePeriod))
        case .cancelledGrace:
            graceTask?.cancel()
            graceTask = nil
            model?.clearCallEndNotice()
        case .pauseSameNote:
            graceTask?.cancel()
            graceTask = nil
            model?.pauseForCallEnd()
        case .resumeSameNote:
            graceTask?.cancel()
            graceTask = nil
            model?.resumeAfterFalseStop()
        }
    }

    private func scheduleGraceExpiry() {
        graceTask?.cancel()
        let duration = callEndGuard.gracePeriod
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.handle(self.callEndGuard.observe(
                signalPresent: false,
                at: ProcessInfo.processInfo.systemUptime
            ))
        }
    }
}
