import XCTest
@testable import LocalDictation

/// Round-tripping is an invariant, not an assumption — `docs/PHASE_3.md` names
/// it as one. If a range cannot survive the trip through the map, every risky
/// span the review strip draws is drawn in the wrong place.
final class EditMapTests: XCTestCase {
    private let service = ConservativeCleanupService()

    private func assertUntouchedWordsRoundTrip(
        _ raw: String,
        language: SpeechLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = service.clean(raw, language: language)
        let rawCharacters = Array(result.raw)
        let cleanedCharacters = Array(result.cleaned)
        let editedRanges = result.edits.map(\.rawRange)

        for word in WordScanner.words(in: result.raw) {
            let touchesAnEdit = editedRanges.contains { $0.overlaps(word.range) }
            let cleanedRange = result.map.cleanedRange(forRaw: word.range)

            XCTAssertLessThanOrEqual(cleanedRange.upperBound, cleanedCharacters.count, file: file, line: line)

            if !touchesAnEdit {
                XCTAssertEqual(
                    String(cleanedCharacters[cleanedRange]),
                    word.text,
                    "an untouched word landed on the wrong characters in “\(raw)”",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    result.map.rawRange(forCleaned: cleanedRange),
                    word.range,
                    "mapping back did not return the original range in “\(raw)”",
                    file: file,
                    line: line
                )
                XCTAssertEqual(String(rawCharacters[word.range]), word.text, file: file, line: line)
            }
        }
    }

    func testUntouchedWordsRoundTripThroughTheMap() {
        assertUntouchedWordsRoundTrip("  ähm bitte überweise 1450 euro an müller  ", language: .german)
        assertUntouchedWordsRoundTrip("der termin ist offen .Müller wartet", language: .german)
        assertUntouchedWordsRoundTrip("das kostet 89 euro", language: .german)
    }

    /// The character-offset convention is what makes this work: an umlaut and a
    /// Cyrillic letter each occupy exactly one position, so an edit early in the
    /// string does not shift later spans by a byte count.
    func testMappingIsCorrectAcrossUmlautsAndCyrillic() {
        assertUntouchedWordsRoundTrip("ähm müller schuldet 1450 euro für die prüfung", language: .german)
        assertUntouchedWordsRoundTrip("переведи 1450 евро мюллеру до пятницы", language: .russian)
        assertUntouchedWordsRoundTrip("переказати 1450 євро мюллеру до п'ятниці", language: .ukrainian)
    }

    func testAWordAfterADeletionShiftsByExactlyTheDeletedLength() {
        let result = service.clean("ich äh brauche das", language: .german)
        // "brauche" sits at raw 7..<14 and moves back by the three characters
        // that "äh " occupied.
        let raw = WordScanner.words(in: result.raw).first { $0.text == "brauche" }!
        let cleaned = result.map.cleanedRange(forRaw: raw.range)

        XCTAssertEqual(String(Array(result.cleaned)[cleaned]), "brauche")
        XCTAssertEqual(cleaned.lowerBound, raw.range.lowerBound - 3)
    }

    /// A range that overlaps a replacement has to grow to cover the whole
    /// replacement, so a span never lands on half of an edit.
    func testARangeTouchingAnEditCoversTheWholeEdit() {
        let result = service.clean("der termin", language: .german)
        let edit = result.edits.first { $0.kind == .capitalization }!

        let mapped = result.map.cleanedRange(forRaw: edit.rawRange)
        XCTAssertEqual(mapped, edit.cleanedRange)
    }

    func testIdentityMapIsExact() {
        let map = EditMap.identity(length: 12)

        XCTAssertFalse(map.hasEdits)
        XCTAssertEqual(map.cleanedRange(forRaw: 3..<7), 3..<7)
        XCTAssertEqual(map.rawRange(forCleaned: 3..<7), 3..<7)
        XCTAssertEqual(map.cleanedRange(forRaw: 0..<12), 0..<12)
    }

    func testOutOfBoundsRangesAreClampedRatherThanTrapping() {
        let result = service.clean("der termin", language: .german)

        let beyond = result.map.cleanedRange(forRaw: 500..<900)
        XCTAssertEqual(beyond.lowerBound, result.map.cleanedLength)
        XCTAssertTrue(beyond.isEmpty)

        let negative = result.map.cleanedRange(forRaw: -5..<2)
        XCTAssertEqual(negative.lowerBound, 0)
    }

    /// Every segment has to be contiguous and monotonic in both coordinate
    /// systems, or a lookup finds the wrong one.
    func testSegmentsTileBothTextsWithoutGapsOrOverlaps() {
        let result = service.clean("  ähm bitte überweise 1450 euro .Müller wartet  ", language: .german)

        var rawPosition = 0
        var cleanedPosition = 0
        for segment in result.map.segments {
            XCTAssertEqual(segment.raw.lowerBound, rawPosition)
            XCTAssertEqual(segment.cleaned.lowerBound, cleanedPosition)
            rawPosition = segment.raw.upperBound
            cleanedPosition = segment.cleaned.upperBound
        }
        XCTAssertEqual(rawPosition, result.map.rawLength)
        XCTAssertEqual(cleanedPosition, result.map.cleanedLength)
        XCTAssertEqual(result.map.rawLength, result.raw.count)
        XCTAssertEqual(result.map.cleanedLength, result.cleaned.count)
    }
}
