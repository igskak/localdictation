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

    func testWithNothingInFocusThereIsNothingToInsertInto() {
        let context = InsertionContext(hasFocusedElement: false, acceptsDirectWrite: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .clipboard(.noEditableField))
    }

    /// Electron and Chromium describe a focused web view as a group and say
    /// nothing about the field inside it. The field is real, it is focused, and
    /// it takes ⌘V — so refusing to insert on the strength of a bad
    /// self-description left the user pasting by hand for no reason.
    func testAFocusedElementThatDescribesNothingIsStillPastedInto() {
        let context = InsertionContext(acceptsDirectWrite: false)
        XCTAssertEqual(InsertionPolicy.plan(for: context), .paste)
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

/// Whether a direct write actually landed.
///
/// This exists because of a live session: Safari reported
/// `inserted:focusedElement`, the app showed no notice — a successful insertion
/// says nothing, by design — and the text never appeared in the field. The
/// Accessibility call had returned `success` and done nothing, and the only
/// honest way to tell is to look at the field afterwards.
final class InsertionVerificationTests: XCTestCase {
    func testAFieldThatGrewTookTheText() {
        let before = TextFieldFingerprint(characterCount: 10, selectionLocation: 10, selectionLength: 0)
        let after = TextFieldFingerprint(characterCount: 15, selectionLocation: 15, selectionLength: 0)
        XCTAssertTrue(InsertionVerification.didApply(before: before, after: after))
    }

    /// Replacing a selection with a string of the same length leaves the count
    /// alone, so the caret is what says the write happened.
    func testAReplacedSelectionOfTheSameLengthIsStillAnInsertion() {
        let before = TextFieldFingerprint(characterCount: 20, selectionLocation: 4, selectionLength: 5)
        let after = TextFieldFingerprint(characterCount: 20, selectionLocation: 9, selectionLength: 0)
        XCTAssertTrue(InsertionVerification.didApply(before: before, after: after))
    }

    /// The Safari case, and the reason this type exists.
    func testAFieldThatDidNotChangeAtAllIgnoredTheWrite() {
        let fingerprint = TextFieldFingerprint(characterCount: 10, selectionLocation: 10, selectionLength: 0)
        XCTAssertFalse(InsertionVerification.didApply(before: fingerprint, after: fingerprint))
    }

    /// Either half on its own is enough to notice a change.
    func testACountAloneIsEnoughToVerify() {
        XCTAssertFalse(
            InsertionVerification.didApply(
                before: TextFieldFingerprint(characterCount: 3),
                after: TextFieldFingerprint(characterCount: 3)
            )
        )
        XCTAssertTrue(
            InsertionVerification.didApply(
                before: TextFieldFingerprint(characterCount: 3),
                after: TextFieldFingerprint(characterCount: 8)
            )
        )
    }

    func testACaretAloneIsEnoughToVerify() {
        XCTAssertFalse(
            InsertionVerification.didApply(
                before: TextFieldFingerprint(selectionLocation: 2, selectionLength: 0),
                after: TextFieldFingerprint(selectionLocation: 2, selectionLength: 0)
            )
        )
        XCTAssertTrue(
            InsertionVerification.didApply(
                before: TextFieldFingerprint(selectionLocation: 2, selectionLength: 0),
                after: TextFieldFingerprint(selectionLocation: 7, selectionLength: 0)
            )
        )
    }

    /// An element that describes nothing cannot be checked, and the API's own
    /// answer stands. Pasting on top of a write that did land would insert the
    /// text twice, which is worse than the silence this check ends.
    func testAnElementThatSaysNothingIsTakenAtItsWord() {
        XCTAssertTrue(
            InsertionVerification.didApply(
                before: TextFieldFingerprint(),
                after: TextFieldFingerprint()
            )
        )
        XCTAssertTrue(
            InsertionVerification.didApply(
                before: TextFieldFingerprint(characterCount: 4),
                after: TextFieldFingerprint()
            )
        )
    }
}
