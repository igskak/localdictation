import XCTest

enum AsyncWaitError: Error {
    case timedOut(String)
}

/// Polls a main-actor condition until it holds. Used instead of arbitrary sleeps
/// so coordinator tests stay deterministic without a microphone.
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("Timed out waiting for: \(description)", file: file, line: line)
    throw AsyncWaitError.timedOut(description)
}
