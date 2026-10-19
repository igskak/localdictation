import XCTest
@testable import Witness

final class ContextCompositorTests: XCTestCase {
    private let service = AdaptiveCleanupService()

    func testContinuationUsesBoundarySpaceAndSourceAwareLowercasing() {
        let context = DictationTextContext(
            category: .emailDocument,
            fieldRole: .editableText,
            textBeforeCaret: "We should",
            textAfterCaret: "",
            hasSelection: false
        )
        let result = service.clean(
            "meet tomorrow",
            language: .english,
            options: CleanupOptions(level: .clean, context: context)
        )
        XCTAssertEqual(result.cleaned, " meet tomorrow.")
        XCTAssertTrue(result.edits.contains { $0.kind == .contextSpacing })
        XCTAssertTrue(result.edits.contains { $0.kind == .contextCapitalization })
    }

    func testMessagingDropsOnlyAShortSingleSentencePeriod() {
        let context = DictationTextContext(
            category: .workMessaging,
            fieldRole: .editableText,
            textBeforeCaret: "",
            textAfterCaret: "",
            hasSelection: false
        )
        let result = service.clean(
            "hello there",
            language: .english,
            options: CleanupOptions(level: .clean, context: context)
        )
        XCTAssertEqual(result.cleaned, "Hello there")
        XCTAssertTrue(result.edits.contains { $0.kind == .contextPunctuation })
    }

    func testCodeAndTerminalDoNotInferListsOrTerminalPeriods() {
        XCTAssertEqual(ApplicationCategory.classify(bundleIdentifier: "com.apple.Terminal"), .codeTerminal)
        XCTAssertEqual(ApplicationCategory.classify(bundleIdentifier: "com.apple.dt.Xcode"), .codeTerminal)
        let context = DictationTextContext(category: .codeTerminal, fieldRole: .editableText,
                                           textBeforeCaret: "", textAfterCaret: "", hasSelection: false)
        let result = service.clean("shopping colon first apples second pears", language: .english,
                                   options: CleanupOptions(level: .clean, context: context))
        XCTAssertFalse(result.edits.contains { $0.kind == .listFormatting })
        XCTAssertFalse(result.cleaned.hasSuffix("."))
        XCTAssertTrue(result.cleaned.contains(":")) // explicit command remains available
    }

    func testASelectionDoesNotInventAJoinOrLowercase() {
        let context = DictationTextContext(
            category: .emailDocument,
            fieldRole: .editableText,
            textBeforeCaret: "replace this",
            textAfterCaret: "please",
            hasSelection: true
        )
        let result = service.clean(
            "hello",
            language: .english,
            options: CleanupOptions(level: .clean, context: context)
        )
        XCTAssertEqual(result.cleaned, "Hello.")
        XCTAssertFalse(result.edits.contains { $0.kind == .contextSpacing || $0.kind == .contextCapitalization })
    }

    func testMissingContextIsExactlyContextFreeClean() {
        let first = service.clean("hello there", language: .english, options: CleanupOptions(level: .clean))
        let second = service.clean("hello there", language: .english, options: CleanupOptions(level: .clean, context: nil))
        XCTAssertEqual(first, second)
    }

    func testCleanRetainsTheConservativeIntermediate() {
        let result = service.clean("twenty percent", language: .english, options: CleanupOptions(level: .clean))
        XCTAssertEqual(result.conservativeText, "Twenty percent.")
        XCTAssertEqual(result.cleaned, "20%")
    }

    func testContextWindowsAreBoundedInUTF16CodeUnits() {
        let value = String(repeating: "🙂", count: 80) + "selected" + String(repeating: "x", count: 80)
        let location = (String(repeating: "🙂", count: 80) as NSString).length
        let windows = AXTextContextService.boundedWindows(
            value: value,
            selection: NSRange(location: location, length: "selected".utf16.count)
        )
        XCTAssertLessThanOrEqual(windows.before.utf16.count, AXTextContextService.beforeLimit)
        XCTAssertLessThanOrEqual(windows.after.utf16.count, AXTextContextService.afterLimit)
        XCTAssertEqual(windows.after, String(repeating: "x", count: 32))
    }
}

@MainActor
final class AXTextContextPrivacyTests: XCTestCase {
    private let target = InsertionTarget(
        processIdentifier: 91,
        bundleIdentifier: "com.example.editor",
        applicationName: "Editor"
    )

    func testSecureInputProducesNoContext() {
        let service = AXTextContextService(
            permissionService: FakeAccessibilityPermissionService(),
            frontmost: FakeFrontmostApplicationSource([.init(processIdentifier: 91)]),
            secureInput: FakeSecureInputSource(.init(isEnabled: true))
        )
        XCTAssertEqual(service.context(for: target), .unavailable)
    }

    func testAStaleTargetProducesNoContext() {
        let service = AXTextContextService(
            permissionService: FakeAccessibilityPermissionService(),
            frontmost: FakeFrontmostApplicationSource([.init(processIdentifier: 92)]),
            secureInput: FakeSecureInputSource()
        )
        XCTAssertEqual(service.context(for: target), .unavailable)
    }

    func testApplicationClassificationIsBundleIdentifierOnly() {
        XCTAssertEqual(ApplicationCategory.classify(bundleIdentifier: "com.apple.Mail"), .emailDocument)
        XCTAssertEqual(ApplicationCategory.classify(bundleIdentifier: "com.tinyspeck.slackmacgap"), .workMessaging)
        XCTAssertEqual(ApplicationCategory.classify(bundleIdentifier: "com.apple.MobileSMS"), .personalMessaging)
        XCTAssertEqual(ApplicationCategory.classify(bundleIdentifier: "com.apple.Terminal"), .codeTerminal)
    }
}

