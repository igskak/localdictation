import Foundation

/// Looks up user-facing copy in the app bundle while keeping English source
/// strings as the fallback and as readable catalog keys.
///
/// SwiftUI localizes literal labels automatically. Presentation models and
/// service adapters return `String`, though, so they use this small boundary
/// rather than leaking localization concerns into recording or transcription.
enum L10n {
    private final class BundleToken {}

    static let bundle = Bundle(for: BundleToken.self)

    static var interfaceLocale: Locale {
        Locale(identifier: bundle.preferredLocalizations.first ?? "en")
    }

    static func string(_ source: String) -> String {
        bundle.localizedString(forKey: source, value: source, table: nil)
    }

    static func format(_ source: String, _ arguments: any CVarArg...) -> String {
        String(
            format: string(source),
            locale: Locale.autoupdatingCurrent,
            arguments: arguments
        )
    }
}
