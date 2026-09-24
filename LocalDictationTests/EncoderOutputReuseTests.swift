import CoreML
import XCTest
@testable import Witness

/// The half of the encoder reuse that needs no model: when an output may be
/// handed back, and when it must not be.
///
/// The rule under test is narrow on purpose. Reuse is only ever a way of not
/// recomputing numbers the encoder already produced for the identical input;
/// anything else — a different recording, a changed byte, a different
/// layout, the end of the utterance — has to make the encoder run again.
final class EncoderOutputReuseTests: XCTestCase {
    private func tensor(_ values: [Float], shape: [NSNumber] = [1, 4]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
        return array
    }

    func testTheSameInputWithinAnUtteranceGetsTheSameOutputBack() throws {
        let reuse = EncoderOutputReuse()
        let input = try tensor([1, 2, 3, 4])
        let output = try tensor([9, 9, 9, 9])

        reuse.beginUtterance()
        XCTAssertNil(reuse.reusedOutput(for: input), "Nothing has been encoded yet")
        reuse.remember(output, for: input)

        // A second, separately built tensor with identical contents: that is
        // what the decode hands over after language detection.
        let sameAgain = try tensor([1, 2, 3, 4])
        XCTAssertTrue(reuse.reusedOutput(for: sameAgain) === output)
        XCTAssertEqual(reuse.endUtterance(), 1)
    }

    func testOneChangedValueMeansTheEncoderRunsAgain() throws {
        let reuse = EncoderOutputReuse()
        reuse.beginUtterance()
        reuse.remember(try tensor([9, 9, 9, 9]), for: try tensor([1, 2, 3, 4]))

        XCTAssertNil(reuse.reusedOutput(for: try tensor([1, 2, 3, 4.0001])))
        XCTAssertEqual(reuse.endUtterance(), 0)
    }

    func testTheSameBytesInADifferentShapeAreNotTheSameInput() throws {
        let reuse = EncoderOutputReuse()
        reuse.beginUtterance()
        reuse.remember(try tensor([9, 9, 9, 9]), for: try tensor([1, 2, 3, 4], shape: [1, 4]))

        XCTAssertNil(reuse.reusedOutput(for: try tensor([1, 2, 3, 4], shape: [2, 2])))
    }

    /// Between utterances nothing is held: an encoder output is derived from
    /// someone's speech and must not outlive the dictation it came from, and
    /// the next dictation must never be answered from the last one.
    func testNothingSurvivesTheEndOfTheUtterance() throws {
        let reuse = EncoderOutputReuse()
        let input = try tensor([1, 2, 3, 4])

        reuse.beginUtterance()
        reuse.remember(try tensor([9, 9, 9, 9]), for: input)
        reuse.endUtterance()

        XCTAssertNil(reuse.reusedOutput(for: input), "Disarmed, so nothing is handed back")
        reuse.beginUtterance()
        XCTAssertNil(reuse.reusedOutput(for: input), "A new utterance starts empty")
    }

    func testOutsideAnUtteranceNothingIsRemembered() throws {
        let reuse = EncoderOutputReuse()
        let input = try tensor([1, 2, 3, 4])

        reuse.remember(try tensor([9, 9, 9, 9]), for: input)
        reuse.beginUtterance()

        XCTAssertNil(reuse.reusedOutput(for: input))
    }
}
