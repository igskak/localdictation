import XCTest
@testable import Witness

@MainActor
final class UpdateRecordingSafetyTests: XCTestCase {
    func testIdleUpdateLeavesRelaunchToSparkle() {
        let updater = AppUpdater(startingUpdater: false, mayRestart: { true })
        XCTAssertTrue(updater.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
        var calls = 0
        XCTAssertFalse(updater.postponeRelaunchIfNeeded { calls += 1 })
        XCTAssertFalse(updater.isWaitingToRestart)
        XCTAssertEqual(calls, 0)
    }

    func testConfirmedUpdateWaitsForBothRecordingAndFinishingThenInstallsOnce() async throws {
        var dictation = RecordingState.recording
        var meetingIsActive = true
        let updater = AppUpdater(startingUpdater: false, mayRestart: {
            DictationEngineChoice.allowsRestart(dictation: dictation, meetingIsActive: meetingIsActive)
        })
        var calls = 0
        XCTAssertTrue(updater.postponeRelaunchIfNeeded { calls += 1 })
        XCTAssertTrue(updater.isWaitingToRestart)
        dictation = .transcribing
        meetingIsActive = false
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(updater.isWaitingToRestart)
        dictation = .ready
        try await waitUntil("safe update relaunch") { calls == 1 }
        XCTAssertFalse(updater.isWaitingToRestart)
        updater.cancelPendingInstallation()
        XCTAssertEqual(calls, 1)
    }

    func testPausedMeetingStillProtectsTheUpdateBoundary() {
        let status = NotetakerStatus()
        status.update(.paused)
        let updater = AppUpdater(startingUpdater: false, mayRestart: {
            DictationEngineChoice.allowsRestart(dictation: .ready, meetingIsActive: status.isActive)
        })
        XCTAssertTrue(updater.postponeRelaunchIfNeeded { XCTFail("Paused note must not be interrupted") })
        updater.cancelPendingInstallation()
    }

    func testAbortedInstallationCannotResumeAfterRecordingFinishes() async throws {
        var ready = false
        let updater = AppUpdater(startingUpdater: false, mayRestart: { ready })
        var calls = 0
        XCTAssertTrue(updater.postponeRelaunchIfNeeded { calls += 1 })
        updater.cancelPendingInstallation()
        ready = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(updater.isWaitingToRestart)
    }
}
