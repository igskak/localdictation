import Foundation

struct DictationTextContext: Sendable, Equatable {
    let category: ApplicationCategory
    let fieldRole: TextFieldRole
    let textBeforeCaret: String
    let textAfterCaret: String
    let hasSelection: Bool
}

enum TextContextAvailability: Sendable, Equatable {
    case available(DictationTextContext)
    case unavailable

    var context: DictationTextContext? {
        guard case let .available(context) = self else { return nil }
        return context
    }
}

@MainActor
protocol TextContextService: AnyObject {
    /// Reads ephemeral context for the captured application. Implementations
    /// must return unavailable rather than waiting beyond their fixed timeout.
    func context(for target: InsertionTarget?) -> TextContextAvailability
}

@MainActor
final class UnavailableTextContextService: TextContextService {
    func context(for target: InsertionTarget?) -> TextContextAvailability { .unavailable }
}

