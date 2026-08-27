import XCTest
@testable import LocalDictation

/// A profile is an ordered set since Phase 7. These are the properties the rest
/// of the app is entitled to assume: it is never empty, it never repeats a
/// language, and its first member is the one the engine falls back to.
final class LanguageProfileTests: XCTestCase {
    func testEveryVerifiedLanguageStillHasASingleLanguageProfile() {
        XCTAssertEqual(Set(LanguageProfile.single.map(\.primary)), Set(SpeechLanguage.verified))
    }

    func testTheCombinationsPhaseSixShippedAreUnchanged() {
        XCTAssertEqual(
            LanguageProfile.mixed.map(\.id),
            ["de+en", "ru+uk", "ru+en", "uk+en"]
        )
    }

    func testAProfileKeepsTheOrderItWasGivenAndTheFirstIsPreferred() {
        let profile = LanguageProfile(.russian, .english, .ukrainian)

        XCTAssertEqual(profile.languages, [.russian, .english, .ukrainian])
        XCTAssertEqual(profile.primary, .russian)
        XCTAssertEqual(profile.id, "ru+en+uk")
        XCTAssertEqual(profile.shortLabel, "RU+EN+UK")
        XCTAssertEqual(profile.displayName, "Russian + English + Ukrainian")
        XCTAssertTrue(profile.isMixed)
    }

    func testALanguageNamedTwiceIsSelectedOnce() {
        XCTAssertEqual(
            LanguageProfile(.russian, .english, .russian).languages,
            [.russian, .english],
            "The first appearance wins, because that is what makes the preferred language survive"
        )
    }

    func testAProfileNamingNothingIsNotAProfile() {
        XCTAssertNil(LanguageProfile(languages: []))
    }

    func testProfileLookupRoundTripsThroughItsIdentifier() throws {
        for profile in LanguageProfile.all + [LanguageProfile(.russian, .english, .ukrainian)] {
            XCTAssertEqual(LanguageProfile.profile(id: profile.id), profile)
        }
    }

    /// Polish is a language a user may now select, so an identifier naming it
    /// resolves. An identifier naming something the engine never heard of does
    /// not, so a hand-edited corpus manifest fails loudly.
    func testAnIdentifierResolvesOnlyForLanguagesTheEngineKnows() throws {
        let polish = try XCTUnwrap(SpeechLanguage(rawValue: "pl"))
        XCTAssertEqual(LanguageProfile.profile(id: "pl"), LanguageProfile(polish))
        XCTAssertNil(LanguageProfile.profile(id: "klingon"))
        XCTAssertNil(LanguageProfile.profile(id: "de+klingon"))
        XCTAssertNil(LanguageProfile.profile(id: ""))
    }

    func testTheDefaultStillTargetsTheInitialMarket() {
        XCTAssertEqual(LanguageProfile.default, .germanEnglish)
    }

    // MARK: - Editing

    func testAddingALanguageLeavesThePreferredOneAlone() {
        let profile = LanguageProfile.russianEnglish.including(.ukrainian)

        XCTAssertEqual(profile.languages, [.russian, .english, .ukrainian])
        XCTAssertEqual(profile.including(.ukrainian), profile, "Adding twice changes nothing")
    }

    func testRemovingALanguageKeepsTheRest() {
        XCTAssertEqual(
            LanguageProfile(.russian, .english, .ukrainian).excluding(.english)?.languages,
            [.russian, .ukrainian]
        )
    }

    /// The picker needs to refuse the last deselection rather than discover
    /// afterwards that the user has no language at all.
    func testRemovingTheLastLanguageIsRefused() {
        XCTAssertNil(LanguageProfile.german.excluding(.german))
    }

    func testPreferringMovesALanguageToTheFrontAndAddsItIfItWasNotThere() {
        XCTAssertEqual(
            LanguageProfile(.russian, .english, .ukrainian).preferring(.ukrainian).languages,
            [.ukrainian, .russian, .english]
        )
        XCTAssertEqual(
            LanguageProfile.german.preferring(.english).languages,
            [.english, .german]
        )
    }

    // MARK: - On disk

    func testAProfileEncodesAsItsLanguageList() throws {
        let data = try JSONEncoder().encode(LanguageProfile(.russian, .english))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["languages"])
        XCTAssertEqual(object["languages"] as? [String], ["ru", "en"])
    }

    /// The shape every build up to Phase 6 wrote. A decoder that did not read
    /// it would take away the choice this phase exists to give.
    func testTheProfileAPhaseSixBuildWroteStillReads() throws {
        let data = Data(#"{"primary":"ru","secondary":"uk"}"#.utf8)

        XCTAssertEqual(try JSONDecoder().decode(LanguageProfile.self, from: data), .russianUkrainian)
    }

    func testAPhaseSixSingleLanguageProfileStillReads() throws {
        let data = Data(#"{"primary":"de"}"#.utf8)

        XCTAssertEqual(try JSONDecoder().decode(LanguageProfile.self, from: data), .german)
    }

    func testAProfileWithNoLanguagesIsRefusedRatherThanDefaulted() {
        let data = Data(#"{"languages":[]}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(LanguageProfile.self, from: data))
    }

    func testAProfileRoundTripsThroughItsOwnEncoding() throws {
        let profile = LanguageProfile(.ukrainian, .english, .german)
        let data = try JSONEncoder().encode(profile)

        XCTAssertEqual(try JSONDecoder().decode(LanguageProfile.self, from: data), profile)
    }
}
