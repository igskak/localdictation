import SwiftUI

/// The list of languages, wherever it is shown.
///
/// One view for the first run and for Settings, because they are the same
/// question asked twice and answering it differently in two places is how a
/// setting starts meaning two things.
///
/// The two tiers are separated visually rather than by hiding anything. A user
/// who speaks Polish is not helped by a product that pretends Polish does not
/// exist; they are helped by being told, before they choose it, that Polish
/// gets recognition and not the review marks the other four get.
struct LanguageSelectionEditor: View {
    @Binding var selection: LanguageProfile

    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search languages", text: $search)
                .textFieldStyle(.roundedBorder)

            List {
                if !verifiedMatches.isEmpty {
                    Section("Measured end to end") {
                        ForEach(verifiedMatches) { row($0) }
                    }
                }

                if !otherMatches.isEmpty {
                    Section("Everything else the engine knows") {
                        ForEach(otherMatches) { row($0) }
                    }
                }

                if verifiedMatches.isEmpty, otherMatches.isEmpty {
                    Text("No language here is called \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)

            Text("German, English, Russian, and Ukrainian are measured end to end: recognition, cleanup, and every mark the review can show. The rest are recognized, and the marks that are calibrated per language stay off rather than guess.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            preferredRow
        }
    }

    // MARK: - Rows

    private func row(_ language: SpeechLanguage) -> some View {
        Toggle(isOn: binding(for: language)) {
            HStack(spacing: 6) {
                Text(language.displayName)
                if language.nativeName != language.displayName {
                    Text(language.nativeName)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The last selected language cannot be turned off. Refusing it here is
        // the only place it can be said; refusing it silently afterwards would
        // read as a toggle that does not work.
        .disabled(selection.languages == [language])
    }

    @ViewBuilder
    private var preferredRow: some View {
        if selection.isMixed {
            HStack {
                Picker("Preferred", selection: preferred) {
                    ForEach(selection.languages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
            }

            Text("The preferred language decides a short phrase that could be either — \u{201C}okay\u{201D}, \u{201C}ja\u{201D}, a name on its own. A sentence long enough to be recognized is decided by what was said, not by this.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bindings

    private func binding(for language: SpeechLanguage) -> Binding<Bool> {
        Binding(
            get: { selection.contains(language) },
            set: { isOn in
                if isOn {
                    selection = selection.including(language)
                } else if let reduced = selection.excluding(language) {
                    selection = reduced
                }
            }
        )
    }

    private var preferred: Binding<SpeechLanguage> {
        Binding(
            get: { selection.primary },
            set: { selection = selection.preferring($0) }
        )
    }

    // MARK: - Search

    private var verifiedMatches: [SpeechLanguage] {
        SpeechLanguage.verified.filter(matches)
    }

    private var otherMatches: [SpeechLanguage] {
        SpeechLanguage.all.filter { !$0.isVerified && matches($0) }
    }

    /// Matches the English name, the native name, or the code, so someone
    /// looking for their own language finds it under the name they call it.
    private func matches(_ language: SpeechLanguage) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return language.displayName.localizedCaseInsensitiveContains(query)
            || language.nativeName.localizedCaseInsensitiveContains(query)
            || language.rawValue.localizedCaseInsensitiveCompare(query) == .orderedSame
    }
}
