import XCTest
@testable import Witness

/// The queue that lets dictation and the Notetaker share one loaded speech
/// model. A dictation and a meeting window must never run on the engine at
/// once, and neither may be skipped or reordered.
final class InferenceTurnsTests: XCTestCase {
    func testTheFirstCallerRunsAtOnce() {
        var turns = InferenceTurns<String>()

        XCTAssertTrue(turns.enter())
        XCTAssertTrue(turns.isBusy)
    }

    func testLaterCallersWaitAndRunInArrivalOrder() {
        var turns = InferenceTurns<String>()
        XCTAssertTrue(turns.enter(), "A meeting window takes the engine")

        XCTAssertFalse(turns.enter())
        turns.wait("dictation")
        XCTAssertFalse(turns.enter())
        turns.wait("next window")
        XCTAssertEqual(turns.waitingCount, 2)

        XCTAssertEqual(turns.leave(), "dictation")
        XCTAssertTrue(turns.isBusy, "The turn passes on without the engine going idle in between")
        XCTAssertEqual(turns.leave(), "next window")
        XCTAssertNil(turns.leave())
        XCTAssertFalse(turns.isBusy)
    }

    func testAFreedEngineIsTakenWithoutWaiting() {
        var turns = InferenceTurns<String>()
        XCTAssertTrue(turns.enter())
        XCTAssertNil(turns.leave())

        XCTAssertTrue(turns.enter())
        XCTAssertEqual(turns.waitingCount, 0)
    }

    func testTheMeetingClientUsesTheDictationEngine() {
        let speech = WhisperKitTranscriptionService()
        let client = speech.meetingClient

        XCTAssertTrue(client.service === speech, "A second engine would load the model a second time")
        XCTAssertEqual(client.identifier, speech.identifier)
    }
}
