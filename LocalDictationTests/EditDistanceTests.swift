import XCTest
@testable import Witness

final class EditDistanceTests: XCTestCase {
    func testDistanceCountsSubstitutionsInsertionsAndDeletions() {
        XCTAssertEqual(EditDistance.distance("Müller", "Müller", limit: 2), 0)
        XCTAssertEqual(EditDistance.distance("Miller", "Müller", limit: 2), 1)
        XCTAssertEqual(EditDistance.distance("Mller", "Müller", limit: 2), 1)
        XCTAssertEqual(EditDistance.distance("Muellerr", "Müller", limit: 3), 3)
    }

    func testDistanceBeyondTheLimitIsNotComputed() {
        XCTAssertNil(EditDistance.distance("Rechnung", "Müller", limit: 2))
        XCTAssertNil(EditDistance.distance("a", "abcdef", limit: 2))
    }

    func testEmptyStringsAreHandled() {
        XCTAssertEqual(EditDistance.distance("", "", limit: 1), 0)
        XCTAssertEqual(EditDistance.distance("ab", "", limit: 2), 2)
        XCTAssertNil(EditDistance.distance("abc", "", limit: 2))
    }

    /// Cyrillic and umlauts are one `Character` each, so a single wrong letter
    /// is a distance of one rather than of however many bytes it takes.
    func testMultiByteCharactersCountAsOne() {
        XCTAssertEqual(EditDistance.distance("Шнайдер", "Шнейдер", limit: 2), 1)
        XCTAssertEqual(EditDistance.distance("Müller", "Muller", limit: 2), 1)
        // "ß" against "ss" is one letter against two, so it is genuinely two
        // edits — the distance counts characters, not bytes and not sounds.
        XCTAssertEqual(EditDistance.distance("Grüße", "Grüsse", limit: 2), 2)
    }
}
