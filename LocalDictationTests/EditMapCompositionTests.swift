import XCTest
@testable import Witness

final class EditMapCompositionTests: XCTestCase {
    func testComposedMapProjectsAcrossDeletionThenInsertion() throws {
        let service = ConservativeCleanupService()
        let first = service.clean(
            "  uh hello world  ",
            language: .english,
            options: CleanupOptions(capitalizesSentences: false, addsTerminalPunctuation: false)
        )
        let second = service.clean(
            first.cleaned,
            language: .english,
            options: CleanupOptions(collapsesWhitespace: false, fixesPunctuationSpacing: false, removesFillers: false)
        )
        let result = try XCTUnwrap(EditMapComposition.append(second, to: first))

        XCTAssertEqual(result.raw, "  uh hello world  ")
        XCTAssertEqual(result.cleaned, "Hello world.")
        let rawWorld = try XCTUnwrap(WordScanner.words(in: result.raw).first { $0.text == "world" })
        let cleanWorld = result.map.cleanedRange(forRaw: rawWorld.range)
        XCTAssertEqual(String(Array(result.cleaned)[cleanWorld]), "world")
        XCTAssertEqual(result.map.rawRange(forCleaned: cleanWorld), rawWorld.range)
    }

    func testCompositionRejectsDisconnectedStages() {
        let first = CleanupResult.unchanged("one", language: .english)
        let second = CleanupResult.unchanged("two", language: .english)
        XCTAssertNil(EditMapComposition.append(second, to: first))
    }

    func testGeneratedIdentityCompositionsStayMonotonicAndBounded() throws {
        for length in 0...128 {
            let first = EditMap.identity(length: length)
            let second = EditMap.identity(length: length)
            let composed = try XCTUnwrap(first.composed(with: second))
            var previous = 0
            for offset in 0...length {
                let mapped = composed.cleanedStart(forRaw: offset)
                XCTAssertGreaterThanOrEqual(mapped, previous)
                XCTAssertLessThanOrEqual(mapped, length)
                XCTAssertEqual(composed.rawStart(forCleaned: mapped), offset)
                previous = mapped
            }
        }
    }
}
