import XCTest
@testable import LocalDictation

final class GlossaryTests: XCTestCase {
    func testTermsAreScopedByLanguage() {
        var glossary = Glossary()
        glossary.add("Müller", language: .german)
        glossary.add("Мюллер", language: .russian)

        XCTAssertEqual(glossary.entries(for: SpeechLanguage.german).map(\.term), ["Müller"])
        XCTAssertEqual(glossary.entries(for: LanguageProfile.russianEnglish).map(\.term), ["Мюллер"])
        XCTAssertEqual(glossary.entries(for: LanguageProfile.germanEnglish).map(\.term), ["Müller"])
    }

    func testBlanksAndDuplicatesAreRejected() {
        var glossary = Glossary()

        XCTAssertTrue(glossary.add("Müller", language: .german))
        XCTAssertFalse(glossary.add("  müller ", language: .german), "case and padding do not make a new term")
        XCTAssertFalse(glossary.add("   ", language: .german))
        XCTAssertTrue(glossary.add("Müller", language: .english), "the same word in another language is another term")
        XCTAssertEqual(glossary.entries.count, 2)
    }

    func testRemovalReportsWhetherAnythingChanged() {
        var glossary = Glossary()
        glossary.add("Müller", language: .german)
        let id = glossary.entries[0].id

        XCTAssertTrue(glossary.remove(id: id))
        XCTAssertFalse(glossary.remove(id: id))
        XCTAssertTrue(glossary.entries.isEmpty)
    }
}

/// Persistence appears for the first time in Phase 3, and it is allowed to hold
/// exactly one thing.
final class FileGlossaryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localdictation-glossary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> FileGlossaryStore {
        FileGlossaryStore(url: directory.appendingPathComponent("glossary.json"))
    }

    func testTermsSurviveAReload() throws {
        var glossary = Glossary()
        glossary.add("Müller", language: .german)
        glossary.add("Мюллер", language: .russian)
        glossary.add("з'їзд", language: .ukrainian)

        try store().save(glossary)
        let reloaded = try store().load()

        XCTAssertEqual(reloaded, glossary)
        XCTAssertEqual(reloaded.entries(for: SpeechLanguage.ukrainian).map(\.term), ["з'їзд"])
    }

    func testAMissingFileIsAnEmptyDictionaryRatherThanAnError() throws {
        XCTAssertEqual(try store().load(), .empty)
    }

    func testAnUnreadableFileSurfacesAnActionableError() throws {
        let url = directory.appendingPathComponent("glossary.json")
        try Data("not json at all".utf8).write(to: url)

        XCTAssertThrowsError(try store().load()) { error in
            guard case .unreadable = error as? GlossaryStoreError else {
                return XCTFail("expected an unreadable error, got \(error)")
            }
        }
    }

    /// The persisted payload is the entire on-disk state of the app. Nothing
    /// derived from an utterance may appear in it.
    func testOnlyTermsAndLanguagesAreWrittenToDisk() throws {
        var glossary = Glossary()
        glossary.add("Müller", language: .german)
        try store().save(glossary)

        let contents = try String(contentsOf: directory.appendingPathComponent("glossary.json"), encoding: .utf8)

        XCTAssertTrue(contents.contains("Müller"))
        XCTAssertTrue(contents.contains("\"de\""))
        for forbidden in ["transcript", "audio", "samples", "confidence", "text\":\"Bitte"] {
            XCTAssertFalse(contents.contains(forbidden), "the dictionary file contains \(forbidden)")
        }
    }
}
