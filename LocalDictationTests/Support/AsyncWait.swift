import XCTest

enum AsyncWaitError: Error {
    case timedOut(String)
}

/// Polls a main-actor condition until it holds. Used instead of arbitrary sleeps
/// so coordinator tests stay deterministic without a microphone.
///
/// **The deadline is generous on purpose, and it used to be three seconds.**
///
/// This suite runs its classes in parallel — eight cores, several runner
/// processes, each doing real async work — and it is run on a laptop that also
/// builds, notarizes and indexes. Measured at a load average above 40, three
/// seconds was not enough: a full run failed about one time in three, always
/// with `Timed out waiting for`, and never twice on the same test. Six
/// unrelated classes were seen failing in one run. Serially, the same suite
/// passed five times out of five.
///
/// So the number was measuring the machine rather than the product. Raising it
/// costs nothing when things work — the loop returns the moment the condition
/// holds, and it is polled every two milliseconds — and the only price is that
/// a test which is genuinely stuck takes longer to say so. A false failure is
/// worth more than that: it teaches everybody to re-run the suite instead of
/// reading it.
///
/// Pass a smaller value where the point of the test *is* that something
/// happens quickly.
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 10,
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
