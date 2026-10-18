import Foundation

enum ApplicationCategory: String, Sendable, Equatable {
    case emailDocument
    case workMessaging
    case personalMessaging
    case other

    static func classify(bundleIdentifier: String?) -> ApplicationCategory {
        guard let identifier = bundleIdentifier?.lowercased() else { return .other }
        if ["com.apple.mail", "com.apple.textedit", "com.apple.pages", "com.microsoft.word"].contains(identifier) {
            return .emailDocument
        }
        if identifier.contains("slack") || identifier.contains("teams") {
            return .workMessaging
        }
        if ["com.apple.messages", "com.apple.mobilesms", "org.telegram.desktop", "com.tdesktop.telegram", "net.whatsapp.whatsapp"].contains(identifier) {
            return .personalMessaging
        }
        return .other
    }

    var dropsShortTerminalPeriod: Bool {
        self == .workMessaging || self == .personalMessaging
    }
}

enum TextFieldRole: String, Sendable, Equatable {
    case editableText
    case numeric
    case other
}

