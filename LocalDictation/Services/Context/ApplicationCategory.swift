import Foundation

enum ApplicationCategory: String, Sendable, Equatable {
    case emailDocument
    case codeTerminal
    case workMessaging
    case personalMessaging
    case other

    static func classify(bundleIdentifier: String?) -> ApplicationCategory {
        guard let identifier = bundleIdentifier?.lowercased() else { return .other }
        if ["com.apple.terminal", "com.googlecode.iterm2", "com.apple.dt.xcode",
            "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92"].contains(identifier) {
            return .codeTerminal
        }
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

