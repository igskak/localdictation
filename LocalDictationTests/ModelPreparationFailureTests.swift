import XCTest
@testable import Witness

/// The three answers the `model_failed` event can carry, read out of the errors
/// that actually arrive.
///
/// It matters that this is a test rather than a habit: the classification runs
/// once, in the engine, where the real error still exists. Everything above it
/// sees a localized sentence, and a funnel built on matching sentences is a
/// funnel that changes meaning when somebody rewrites one.
final class ModelPreparationFailureTests: XCTestCase {
    func testAnyURLErrorIsTheConnection() {
        XCTAssertEqual(ModelPreparationFailure(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(ModelPreparationFailure(URLError(.timedOut)), .network)
        XCTAssertEqual(ModelPreparationFailure(URLError(.cannotFindHost)), .network)
    }

    func testAFullDiskIsToldApartFromEverythingElse() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))

        XCTAssertEqual(ModelPreparationFailure(cocoa), .storage)
        XCTAssertEqual(ModelPreparationFailure(posix), .storage)
    }

    /// The case `docs/PHASE_2_BENCHMARK.md` records somebody losing an
    /// afternoon to: WhisperKit reports a disk that filled mid-download as a
    /// model that could not be found, and keeps the real reason underneath.
    func testTheReasonIsReadFromUnderneathAMisleadingWrapper() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let reported = NSError(
            domain: "WhisperKit",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Model not found. Please check the model or repo name and try again",
                NSUnderlyingErrorKey: underlying
            ]
        )

        XCTAssertEqual(ModelPreparationFailure(reported), .storage)
    }

    func testAnythingElseIsOtherRatherThanAGuess() {
        XCTAssertEqual(ModelPreparationFailure(TranscriptionError.emptyAudio), .other)
        XCTAssertEqual(
            ModelPreparationFailure(NSError(domain: "CoreML", code: 7)),
            .other
        )
    }

    /// A chain that points at itself is somebody else's data structure, and a
    /// launch must not hang on one.
    func testACircularChainTerminates() {
        let inner = NSError(domain: "A", code: 1)
        let outer = NSError(domain: "B", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
        let looping = NSError(domain: "C", code: 3, userInfo: [NSUnderlyingErrorKey: outer])

        XCTAssertEqual(ModelPreparationFailure(looping), .other)
    }

    /// The engine wraps and classifies in one step, so the reason survives the
    /// boundary the coordinator reads it from.
    func testAClassifiedFailureKeepsBothTheReasonAndTheSentence() {
        let error = TranscriptionError.modelPreparationFailed(.network, detail: "The Internet connection appears to be offline.")

        guard case let .modelPreparationFailed(reason, detail) = error else {
            return XCTFail("the classified failure lost its shape")
        }
        XCTAssertEqual(reason, .network)
        XCTAssertTrue(error.message.contains(detail))
    }
}
