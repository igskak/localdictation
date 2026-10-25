import Foundation
import XCTest
@testable import Witness

final class MeetingDetectionTests: XCTestCase {
    private let detector = MeetingCandidateDetector()

    func testZoomAdapterNeedsActiveLocalZoomAudio() {
        let active = snapshot(pid: 11, name: "zoom.us", bundleID: "us.zoom.xos", output: true)
        let inactive = snapshot(pid: 12, name: "zoom.us", bundleID: "us.zoom.xos", output: false)

        XCTAssertEqual(
            ZoomMeetingDetectionAdapter().candidate(for: active),
            MeetingCandidate(platform: .zoom, processIdentifier: 11, confidence: .confirmed)
        )
        XCTAssertNil(ZoomMeetingDetectionAdapter().candidate(for: inactive))
    }

    func testChromeAdapterIsProbableBecauseItDoesNotReadTabsOrURLs() {
        let chrome = snapshot(
            pid: 21,
            name: "Google Chrome Helper (Renderer)",
            bundleID: "com.google.Chrome.helper.renderer",
            output: true
        )

        XCTAssertEqual(
            ChromeMeetDetectionAdapter().candidate(for: chrome),
            MeetingCandidate(platform: .googleMeet, processIdentifier: 21, confidence: .probable)
        )
    }

    func testSafariAdapterIsProbableAndDoesNotPretendToKnowTheTab() {
        let safari = snapshot(
            pid: 22,
            name: "Safari",
            bundleID: "com.apple.Safari",
            output: true,
            input: true,
            frontmost: true
        )

        XCTAssertEqual(
            SafariMeetingDetectionAdapter().candidate(for: safari),
            MeetingCandidate(platform: .safari, processIdentifier: 22, confidence: .probable)
        )
    }

    func testGenericWebKitHelperIsNotBlindlyAttributedToSafari() {
        let helper = snapshot(
            pid: 23,
            name: "com.apple.WebKit.WebContent",
            bundleID: "com.apple.WebKit.WebContent",
            output: true
        )

        XCTAssertNil(SafariMeetingDetectionAdapter().candidate(for: helper))
    }

    func testDetectorPrefersBrowserUsingMicrophoneWhenTwoBrowsersPlayAudio() {
        let chrome = snapshot(pid: 21, name: "Google Chrome", bundleID: "com.google.Chrome", output: true)
        let safari = snapshot(
            pid: 22,
            name: "Safari",
            bundleID: "com.apple.Safari",
            output: true,
            input: true
        )

        XCTAssertEqual(detector.candidate(in: [chrome, safari])?.platform, .safari)
    }

    func testDetectorIgnoresUnrelatedAudioAndPrefersConfirmedZoom() {
        let music = snapshot(pid: 1, name: "Music", bundleID: "com.apple.Music", output: true)
        let chrome = snapshot(pid: 2, name: "Google Chrome", bundleID: "com.google.Chrome", output: true)
        let zoom = snapshot(pid: 3, name: "zoom.us", bundleID: "us.zoom.xos", output: true)

        XCTAssertEqual(detector.candidate(in: [music, chrome, zoom])?.platform, .zoom)
        XCTAssertNil(detector.candidate(in: [music]))
    }

    func testSuggestionAppearsOnlyOnceForContinuousCandidate() {
        let candidate = MeetingCandidate(platform: .zoom, processIdentifier: 42, confidence: .confirmed)
        var policy = MeetingSuggestionPolicy(cooldown: 60)

        XCTAssertEqual(policy.observe(candidate, at: 0), candidate)
        XCTAssertEqual(policy.accept(), candidate)
        XCTAssertNil(policy.observe(candidate, at: 1))
    }

    func testDismissalCooldownSuppressesReappearingCandidatePerPlatform() {
        let first = MeetingCandidate(platform: .googleMeet, processIdentifier: 42, confidence: .probable)
        let restarted = MeetingCandidate(platform: .googleMeet, processIdentifier: 43, confidence: .probable)
        var policy = MeetingSuggestionPolicy(cooldown: 60)

        XCTAssertEqual(policy.observe(first, at: 0), first)
        XCTAssertEqual(policy.dismiss(at: 1), first)
        XCTAssertNil(policy.observe(nil, at: 2))
        XCTAssertNil(policy.observe(restarted, at: 30))
        XCTAssertNil(policy.observe(nil, at: 31))
        XCTAssertEqual(policy.observe(restarted, at: 62), restarted)
    }

    func testTimedOutSuggestionIsSuppressedWithoutAFalsePositiveEvaluation() {
        let candidate = MeetingCandidate(platform: .safari, processIdentifier: 44, confidence: .probable)
        var policy = MeetingSuggestionPolicy(cooldown: 60)

        XCTAssertEqual(policy.observe(candidate, at: 0), candidate)
        policy.suppress(at: 5)
        XCTAssertNil(policy.visibleCandidate)
        XCTAssertNil(policy.observe(nil, at: 9))
        XCTAssertNil(policy.observe(candidate, at: 30))
        XCTAssertEqual(policy.observe(nil, at: 31), nil)
        XCTAssertEqual(policy.observe(candidate, at: 69), candidate)
    }

    func testCallEndGraceCancelsWhenAudioReturns() {
        var guardPolicy = CallEndGuard(gracePeriod: 30)

        XCTAssertEqual(guardPolicy.observe(signalPresent: false, at: 10), .beganGrace)
        XCTAssertEqual(guardPolicy.secondsRemaining(at: 20), 20)
        XCTAssertEqual(guardPolicy.observe(signalPresent: true, at: 21), .cancelledGrace)
        XCTAssertEqual(guardPolicy.state, .monitoring)
    }

    func testExpiredGraceOnlySuggestsStopAndDismissesWhenAudioReturns() {
        var guardPolicy = CallEndGuard(gracePeriod: 30)

        XCTAssertEqual(guardPolicy.observe(signalPresent: false, at: 10), .beganGrace)
        XCTAssertEqual(guardPolicy.observe(signalPresent: false, at: 40), .suggestStop)
        XCTAssertEqual(guardPolicy.state, .suggestingStop)
        XCTAssertEqual(guardPolicy.observe(signalPresent: true, at: 41), .dismissStopSuggestion)
        XCTAssertEqual(guardPolicy.state, .monitoring)
    }

    func testContinueRecordingCancelsGraceForTheRestOfTheSession() {
        var guardPolicy = CallEndGuard(gracePeriod: 30)
        XCTAssertEqual(guardPolicy.observe(signalPresent: false, at: 0), .beganGrace)
        XCTAssertEqual(guardPolicy.continueRecording(), .cancelledGrace)
        XCTAssertEqual(guardPolicy.state, .ignoredForSession)
        XCTAssertEqual(guardPolicy.observe(signalPresent: false, at: 100), .none)
    }

    func testMetricsKeepZoomMeetAndSafariRatesSeparate() throws {
        var metrics = MeetingDetectionMetrics()
        metrics.record(.truePositive, platform: .zoom)
        metrics.record(.falsePositive, platform: .zoom)
        metrics.record(.truePositive, platform: .googleMeet)
        metrics.record(.falseNegative, platform: .googleMeet)
        metrics.record(.falseNegative, platform: .googleMeet)
        metrics.record(.truePositive, platform: .safari)
        metrics.record(.falsePositive, platform: .safari)

        XCTAssertEqual(metrics.zoom.falsePositiveRate, 0.5)
        XCTAssertEqual(metrics.zoom.falseNegativeRate, 0)
        XCTAssertEqual(metrics.googleMeet.falsePositiveRate, 0)
        XCTAssertEqual(metrics.googleMeet.falseNegativeRate ?? -1, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.safari.falsePositiveRate, 0.5)

        let json = String(decoding: try JSONEncoder().encode(metrics), as: UTF8.self)
        XCTAssertTrue(json.contains("falsePositiveRate"))
        XCTAssertTrue(json.contains("falseNegativeRate"))
        for forbidden in ["title", "url", "participant", "bundle", "processIdentifier"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testVersionOneMetricsMigrateWithoutLosingExistingCounters() throws {
        let data = Data(#"{"schemaVersion":1,"zoom":{"truePositives":2,"falsePositives":0,"falseNegatives":0,"falsePositiveRate":0,"falseNegativeRate":0},"googleMeet":{"truePositives":1,"falsePositives":0,"falseNegatives":0,"falsePositiveRate":0,"falseNegativeRate":0}}"#.utf8)

        let metrics = try JSONDecoder().decode(MeetingDetectionMetrics.self, from: data)

        XCTAssertEqual(metrics.schemaVersion, MeetingDetectionMetrics.currentSchemaVersion)
        XCTAssertEqual(metrics.zoom.truePositives, 2)
        XCTAssertEqual(metrics.googleMeet.truePositives, 1)
        XCTAssertEqual(metrics.safari, MeetingDetectionCounts())
    }

    func testLocalMetricsRecorderPersistsOnlyClosedCounters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingDetectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("metrics.json")
        let recorder = LocalMeetingDetectionMetricsRecorder(url: url)

        await recorder.record(.falsePositive, platform: .zoom)
        await recorder.record(.falseNegative, platform: .googleMeet)
        await recorder.record(.truePositive, platform: .safari)

        let persisted = try JSONDecoder().decode(MeetingDetectionMetrics.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.zoom.falsePositives, 1)
        XCTAssertEqual(persisted.googleMeet.falseNegatives, 1)
        XCTAssertEqual(persisted.safari.truePositives, 1)
    }

    private func snapshot(
        pid: pid_t,
        name: String,
        bundleID: String?,
        output: Bool,
        input: Bool = false,
        frontmost: Bool = false
    ) -> MeetingApplicationSnapshot {
        MeetingApplicationSnapshot(
            processIdentifier: pid,
            localizedName: name,
            bundleIdentifier: bundleID,
            isProducingOutput: output,
            isUsingInput: input,
            isFrontmost: frontmost
        )
    }
}
