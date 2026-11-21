import AppKit
import Foundation

struct MeetingApplicationSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let localizedName: String
    let bundleIdentifier: String?
    let isProducingOutput: Bool
    let isUsingInput: Bool
    let isFrontmost: Bool

    init(
        processIdentifier: pid_t,
        localizedName: String,
        bundleIdentifier: String?,
        isProducingOutput: Bool,
        isUsingInput: Bool = false,
        isFrontmost: Bool = false
    ) {
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
        self.isProducingOutput = isProducingOutput
        self.isUsingInput = isUsingInput
        self.isFrontmost = isFrontmost
    }
}

enum MeetingApplicationKind: Sendable, Equatable {
    case zoom
    case chrome
    case safari
    case other

    static func classify(name: String, bundleIdentifier: String?) -> Self {
        let normalizedName = name.lowercased()
        let bundle = bundleIdentifier?.lowercased()
        if bundle == "us.zoom.xos"
            || bundle?.hasPrefix("us.zoom.") == true
            || normalizedName == "zoom.us"
            || normalizedName.hasPrefix("zoom ") {
            return .zoom
        }
        if bundle?.hasPrefix("com.google.chrome") == true
            || normalizedName == "google chrome"
            || normalizedName.hasPrefix("google chrome helper") {
            return .chrome
        }
        if bundle == "com.apple.safari"
            || bundle?.hasPrefix("com.apple.safari.") == true
            || bundle?.hasPrefix("com.apple.safaritechnologypreview") == true
            || normalizedName == "safari"
            || normalizedName.hasPrefix("safari ") {
            return .safari
        }
        return .other
    }
}

protocol MeetingApplicationDetecting: Sendable {
    func candidate(for snapshot: MeetingApplicationSnapshot) -> MeetingCandidate?
}

/// Zoom can be identified from its local application identity. No window title,
/// meeting title, URL, or participant information is inspected.
struct ZoomMeetingDetectionAdapter: MeetingApplicationDetecting {
    func candidate(for snapshot: MeetingApplicationSnapshot) -> MeetingCandidate? {
        guard snapshot.isProducingOutput,
              MeetingApplicationKind.classify(
                name: snapshot.localizedName,
                bundleIdentifier: snapshot.bundleIdentifier
              ) == .zoom else { return nil }
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
        guard snapshot.isProducingOutput,
              MeetingApplicationKind.classify(
                name: snapshot.localizedName,
                bundleIdentifier: snapshot.bundleIdentifier
              ) == .chrome else { return nil }
        return MeetingCandidate(
            platform: .googleMeet,
            processIdentifier: snapshot.processIdentifier,
            confidence: .probable
        )
    }
}

/// Safari output is enough to offer a possible browser-call suggestion, but it
/// does not reveal which tab or service is producing that audio. Keep the
/// confidence probable and never label it as a confirmed Google Meet call.
struct SafariMeetingDetectionAdapter: MeetingApplicationDetecting {
    func candidate(for snapshot: MeetingApplicationSnapshot) -> MeetingCandidate? {
        guard snapshot.isProducingOutput,
              MeetingApplicationKind.classify(
                name: snapshot.localizedName,
                bundleIdentifier: snapshot.bundleIdentifier
              ) == .safari else { return nil }
        return MeetingCandidate(
            platform: .safari,
            processIdentifier: snapshot.processIdentifier,
            confidence: .probable
        )
    }
}

struct MeetingCandidateDetector: Sendable {
    private let zoom = ZoomMeetingDetectionAdapter()
    private let meet = ChromeMeetDetectionAdapter()
    private let safari = SafariMeetingDetectionAdapter()

    func candidate(in snapshots: [MeetingApplicationSnapshot]) -> MeetingCandidate? {
        let candidates = snapshots.flatMap { snapshot -> [(MeetingCandidate, MeetingApplicationSnapshot)] in
            [
                zoom.candidate(for: snapshot),
                meet.candidate(for: snapshot),
                safari.candidate(for: snapshot)
            ].compactMap { candidate in candidate.map { ($0, snapshot) } }
        }
        return candidates.sorted(by: precedes).first?.0
    }

    func candidate(for option: MeetingProcessOption) -> MeetingCandidate? {
        // A manual start can target an open meeting app before it begins
        // producing output. Classification still stays local and identity-only.
        candidate(in: [MeetingApplicationSnapshot(
            processIdentifier: option.processID,
            localizedName: option.name,
            bundleIdentifier: option.bundleIdentifier,
            isProducingOutput: true,
            isUsingInput: option.isUsingInput,
            isFrontmost: option.isFrontmost
        )])
    }

    private func precedes(
        _ lhs: (MeetingCandidate, MeetingApplicationSnapshot),
        _ rhs: (MeetingCandidate, MeetingApplicationSnapshot)
    ) -> Bool {
        let lhsRank = rank(lhs.0, snapshot: lhs.1)
        let rhsRank = rank(rhs.0, snapshot: rhs.1)
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        return (lhs.0.processIdentifier ?? 0) < (rhs.0.processIdentifier ?? 0)
    }

    private func rank(_ candidate: MeetingCandidate, snapshot: MeetingApplicationSnapshot) -> Int {
        let confidence = switch candidate.confidence {
        case .possible: 1
        case .probable: 2
        case .confirmed: 3
        }
        let microphone = snapshot.isUsingInput ? 100 : 0
        let frontmost = snapshot.isFrontmost ? 10 : 0
        return confidence * 1_000 + microphone + frontmost
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

    /// A timed-out panel is suppressed like a dismissal, but is not evidence
    /// that detection was wrong and therefore must not affect FP metrics.
    mutating func suppress(at now: TimeInterval) {
        guard let candidate = visibleCandidate else { return }
        dismissedAt[candidate.platform] = now
        visibleCandidate = nil
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
    case suggestStop
    case dismissStopSuggestion
}

enum CallEndGuardState: Sendable, Equatable {
    case monitoring
    case grace(deadline: TimeInterval)
    case suggestingStop
    case ignoredForSession
}

/// Pure call-end policy. Missing audio can only suggest an explicit user action;
/// it never pauses or finalizes a recording on its own.
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
            state = .suggestingStop
            return .suggestStop
        case (.grace, false), (.suggestingStop, false):
            return .none
        case (.suggestingStop, true):
            state = .monitoring
            return .dismissStopSuggestion
        }
    }

    mutating func continueRecording() -> CallEndGuardAction {
        let action: CallEndGuardAction = state == .suggestingStop ? .dismissStopSuggestion : .cancelledGrace
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
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    var zoom: MeetingDetectionCounts
    var googleMeet: MeetingDetectionCounts
    var safari: MeetingDetectionCounts

    init(
        zoom: MeetingDetectionCounts = .init(),
        googleMeet: MeetingDetectionCounts = .init(),
        safari: MeetingDetectionCounts = .init()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.zoom = zoom
        self.googleMeet = googleMeet
        self.safari = safari
    }

    mutating func record(_ evaluation: MeetingDetectionEvaluation, platform: MeetingPlatform) {
        switch platform {
        case .zoom: zoom.record(evaluation)
        case .googleMeet: googleMeet.record(evaluation)
        case .safari: safari.record(evaluation)
        case .manual, .file: break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case zoom
        case googleMeet
        case safari
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard encodedVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported meeting detection metrics schema"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        zoom = try container.decodeIfPresent(MeetingDetectionCounts.self, forKey: .zoom) ?? .init()
        googleMeet = try container.decodeIfPresent(MeetingDetectionCounts.self, forKey: .googleMeet) ?? .init()
        safari = try container.decodeIfPresent(MeetingDetectionCounts.self, forKey: .safari) ?? .init()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(googleMeet, forKey: .googleMeet)
        try container.encode(safari, forKey: .safari)
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
    typealias CallEndSuggestionHandler = (Bool) -> Void

    private weak var model: DebugMeetingModel?
    private let resolver: any MeetingProcessResolving
    private let detector: MeetingCandidateDetector
    private let metrics: LocalMeetingDetectionMetricsRecorder
    private let onSuggestion: SuggestionHandler
    private let onCallEndSuggestion: CallEndSuggestionHandler
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
        onSuggestion: @escaping SuggestionHandler,
        onCallEndSuggestion: @escaping CallEndSuggestionHandler = { _ in }
    ) {
        self.model = model
        self.resolver = resolver
        self.detector = detector
        self.metrics = metrics
        self.suggestionPolicy = suggestionPolicy
        self.onSuggestion = onSuggestion
        self.onCallEndSuggestion = onCallEndSuggestion
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
        onCallEndSuggestion(false)
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

    func expireSuggestion() {
        suggestionPolicy.suppress(at: ProcessInfo.processInfo.systemUptime)
        onSuggestion(nil)
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
        onCallEndSuggestion(false)
    }

    func continueRecording() {
        graceTask?.cancel()
        graceTask = nil
        handle(callEndGuard.continueRecording())
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
                bundleIdentifier: process.bundleIdentifier ?? application?.bundleIdentifier,
                isProducingOutput: process.isProducingOutput,
                isUsingInput: process.isUsingInput,
                isFrontmost: application?.isActive == true
            )
        }
        latestCandidate = detector.candidate(in: snapshots)

        if let activeCandidate {
            let signalPresent = snapshots.contains {
                $0.processIdentifier == activeCandidate.processIdentifier
                    && ($0.isProducingOutput || $0.isUsingInput)
            }
            guard model?.paused != true else { return }
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
            break
        case .beganGrace:
            scheduleGraceExpiry()
        case .cancelledGrace:
            graceTask?.cancel()
            graceTask = nil
            onCallEndSuggestion(false)
        case .suggestStop:
            graceTask?.cancel()
            graceTask = nil
            onCallEndSuggestion(true)
        case .dismissStopSuggestion:
            graceTask?.cancel()
            graceTask = nil
            onCallEndSuggestion(false)
        }
    }

    private func scheduleGraceExpiry() {
        graceTask?.cancel()
        let duration = callEndGuard.gracePeriod
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.model?.paused != true else { return }
            self.handle(self.callEndGuard.observe(
                signalPresent: false,
                at: ProcessInfo.processInfo.systemUptime
            ))
        }
    }
}
