import SwiftUI

/// The list of languages, wherever it is shown.
///
/// One view for the first run and for Settings, because they are the same
/// question asked twice and answering it differently in two places is how a
/// setting starts meaning two things.
///
/// The two tiers are separated visually rather than by hiding anything. A user
/// who speaks Polish is not helped by a product that pretends Polish does not
/// exist; they are helped by being told, before they choose it, which parts of
/// recognition, verification, and cleanup have actually been measured.
struct LanguageSelectionEditor: View {
    @Binding var selection: LanguageProfile

    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search languages", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .accessibilityLabel("Search languages")

            List {
                if !verifiedMatches.isEmpty {
                    Section("Recognition, cleanup and review") {
                        ForEach(verifiedMatches) { row($0) }
                    }
                }

                if !riskCalibratedMatches.isEmpty {
                    Section("Recognition and review") {
                        ForEach(riskCalibratedMatches) { row($0) }
                    }
                }

                if !otherMatches.isEmpty {
                    Section("More recognition languages") {
                        ForEach(otherMatches) { row($0) }
                    }
                }

                if verifiedMatches.isEmpty, riskCalibratedMatches.isEmpty, otherMatches.isEmpty {
                    Text(verbatim: L10n.format("No languages match “%@”.", search))
                        .foregroundStyle(WitnessStyle.muted)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)
            .scrollContentBackground(.hidden)
            .background(WitnessStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius, style: .continuous)
                    .stroke(WitnessStyle.line, lineWidth: 1)
            }

            DisclosureGroup("Language support") {
                Text("German, English, Russian and Ukrainian support tested recognition, cleanup and review. Spanish, Italian and French also have calibrated review marks; advanced cleanup remains limited. Other languages support recognition without language-specific review rules.")
                    .font(.caption).foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.caption)

            preferredRow
        }
        .toggleStyle(.checkbox)
        .tint(WitnessStyle.accent)
    }

    // MARK: - Rows

    private func row(_ language: SpeechLanguage) -> some View {
        Toggle(isOn: binding(for: language)) {
            HStack(spacing: 6) {
                Text(language.displayName)
                if language.nativeName != language.displayName {
                    Text(language.nativeName)
                        .foregroundStyle(WitnessStyle.muted)
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

            Text("For short or ambiguous phrases, Witness favors your preferred language.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
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
        SpeechLanguage.all.filter { !$0.hasCalibratedRiskSignals && matches($0) }
    }

    private var riskCalibratedMatches: [SpeechLanguage] {
        SpeechLanguage.riskCalibrated.filter { !$0.isVerified && matches($0) }
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
