import XCTest
@testable import LocalDictation

/// The choice between writing, pasting, copying, and refusing, exercised as the
/// pure function it is — no Accessibility call, no pasteboard, no target app.
final class InsertionPolicyTests: XCTestCase {
    func testASettableFocusedFieldIsWrittenDirectly() {
        XCTAssertEqual(InsertionPolicy.plan(for: InsertionContext()), .write)
    }

    func testAFieldThatCannotBeWrittenIsPastedInto() {
        let context = InsertionContext(acceptsDirectWrite: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .paste)
    }

    // MARK: - The clipboard is a result, not a failure

    func testWithoutTrustTheTextGoesToTheClipboard() {
        let context = InsertionContext(isTrusted: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .clipboard(.notTrusted))
    }

    func testDictatingWithNoOtherApplicationInFrontGoesToTheClipboard() {
        let context = InsertionContext(hasTarget: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .clipboard(.noTarget))
    }

    /// The rule that makes a wrong target impossible: the app does not guess.
    func testAMovedTargetIsNeverGuessedAt() {
        let context = InsertionContext(targetIsCurrent: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .clipboard(.targetChanged))
    }

    /// Moving between fields of the same application is a wrong target too, and
    /// says so in its own words.
    func testMovingToAnotherFieldOfTheSameApplicationIsAlsoAWrongTarget() {
        let context = InsertionContext(focusIsCurrent: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .clipboard(.focusChanged))
    }

    func testWithNoTextFieldInFocusThereIsNothingToInsertInto() {
        let context = InsertionContext(hasEditableField: false, acceptsDirectWrite: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .clipboard(.noEditableField))
    }

    // MARK: - Refusal

    func testAPasswordFieldIsRefused() {
        let context = InsertionContext(focusedFieldIsSecure: true)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .refuse(.secureField))
    }

    func testSecureInputIsRefused() {
        let context = InsertionContext(secureInputEnabled: true)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .refuse(.secureInput))
    }

    /// Secure input is checked before trust on purpose. It is readable without
    /// Accessibility, and it must suppress the clipboard as well as the
    /// insertion — otherwise an untrusted app would answer "copied to the
    /// clipboard" for text spoken at a login screen.
    func testSecureInputOutranksTheTrustCheckSoNothingIsCopiedAtALoginScreen() {
        let context = InsertionContext(isTrusted: false, secureInputEnabled: true)
        let plan = InsertionPolicy.plan(for: context)

        XCTAssertEqual(plan, .refuse(.secureInput))
        if case let .clipboard(reason) = plan {
            XCTFail("a login screen must not leave dictation on the clipboard, got \(reason)")
        }
    }

    /// Every refusal leaves the pasteboard alone, and every clipboard outcome
    /// is on it. Asserted over the cases rather than one by one, so a new
    /// reason cannot quietly get this wrong.
    func testOnlyClipboardOutcomesPutTextOnTheClipboard() {
        for reason in ClipboardReason.allCases {
            XCTAssertTrue(InsertionOutcome.copiedToClipboard(reason).isOnClipboard)
            XCTAssertFalse(InsertionOutcome.copiedToClipboard(reason).didInsert)
            XCTAssertNotNil(InsertionOutcome.copiedToClipboard(reason).message)
        }
        for reason in RefusalReason.allCases {
            XCTAssertFalse(InsertionOutcome.refused(reason).isOnClipboard)
            XCTAssertNotNil(InsertionOutcome.refused(reason).message)
        }
        for method in InsertionMethod.allCases {
            XCTAssertTrue(InsertionOutcome.inserted(method).didInsert)
            XCTAssertFalse(InsertionOutcome.inserted(method).isOnClipboard)
            XCTAssertNil(
                InsertionOutcome.inserted(method).message,
                "an insertion says nothing: the text appearing is the message"
            )
        }
    }
}

/// The one thing the app is allowed to invent about the surroundings.
final class InsertionSpacingTests: XCTestCase {
    func testASpaceIsAddedAfterAWord() {
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "t", text: "hello"), " ")
    }

    func testNoSpaceIsAddedAfterASpace() {
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: " ", text: "hello"), "")
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "\n", text: "hello"), "")
    }

    /// An empty field, or one whose contents could not be read. Inventing a
    /// space here would put one at the start of the document.
    func testNoSpaceIsAddedWhenNothingCanBeRead() {
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: nil, text: "hello"), "")
    }

    func testNoSpaceIsAddedAfterAnOpeningBracketOrQuote() {
        for opener: Character in ["(", "[", "«", "„", "\"", "@", "/"] {
            XCTAssertEqual(
                InsertionSpacing.prefix(forCharacterBefore: opener, text: "hello"),
                "",
                "a space after \(opener) would be wrong"
            )
        }
    }

    func testNoSpaceIsAddedWhenTheTextBringsItsOwn() {
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "t", text: " hello"), "")
    }

    /// Dictating a fragment that starts with punctuation — the user said
    /// "comma" and the cleanup produced one.
    func testNoSpaceIsAddedBeforeAttachingPunctuation() {
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "t", text: ", and then"), "")
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "t", text: "."), "")
    }

    /// Cyrillic and umlauts are the normal case in this product, not an edge.
    func testTheRuleWorksOnCyrillicAndUmlauts() {
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "т", text: "привет"), " ")
        XCTAssertEqual(InsertionSpacing.prefix(forCharacterBefore: "ü", text: "Prüfung"), " ")
    }
}
