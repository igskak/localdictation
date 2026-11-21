import AppKit
import SwiftUI

enum MenuBarTab: String, CaseIterable {
    case dictation, notetaker, files
}

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var notetakerStatus: NotetakerStatus
    @ObservedObject private var modelSelection: SpeechModelSelection
    @State private var tab: MenuBarTab = .dictation
    @State private var showsResult = false
    @State private var contentHeight: CGFloat = 420
    private let notetaker: any NotetakerFacade
    private let fileTranscription: FileTranscriptionFeature?

    init(
        notetaker: any NotetakerFacade = UnavailableNotetakerFacade(),
        fileTranscription: FileTranscriptionFeature? = nil,
        modelSelection: SpeechModelSelection = .shared,
        initialTab: MenuBarTab = .dictation
    ) {
        self.notetaker = notetaker
        self.fileTranscription = fileTranscription
        _notetakerStatus = ObservedObject(wrappedValue: notetaker.status)
        self.modelSelection = modelSelection
        _tab = State(initialValue: initialTab)
    }

    private var presentation: StatusPresentation {
        StatusPresentation(state: coordinator.state, binding: coordinator.binding,
            modelState: coordinator.transcriptionModelState, attentionIsPending: coordinator.attentionIsPending,
            silentResult: coordinator.silentResult, captureInterruption: coordinator.captureInterruptionMessage,
            activation: coordinator.activation)
    }
    private var hasNotetaker: Bool { notetaker.menuBarItem != nil }
    private var maximumHeight: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 80) }

    var body: some View {
        ScrollView {
            panel.onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .scrollDisabled(contentHeight <= maximumHeight)
        .frame(width: 398, height: min(contentHeight, maximumHeight))
        .witnessWindow()
        .onAppear {
            coordinator.refreshAuthorization()
            Task { await coordinator.refreshTranscriptionModelState() }
        }
        .onChange(of: coordinator.effectiveProfile) {
            Task { await coordinator.refreshTranscriptionModelState() }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                WitnessBrand(compact: true)
                Spacer()
                Label("On this Mac", systemImage: "lock")
                    .font(.caption2).foregroundStyle(WitnessStyle.muted)
                Menu {
                    Button("Setup and practice") { AppDelegate.showSetup?() }
                    Divider()
                    Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More actions")
            }
            if hasNotetaker || fileTranscription != nil { tabs }
            // Recording and actionable notices belong above both tabs.
            if notetakerStatus.isActive || notetakerStatus.state == .attention { meetingActivity }
            if let suggestion = notetaker.suggestion { MeetingSuggestionCard(suggestion: suggestion) }
            globalNotices
            if let fileTranscription, coordinator.isFileTranscriptionRunning, tab != .files {
                HStack {
                    Label("Transcribing a file", systemImage: "waveform")
                    Spacer()
                    Button("Open") { fileTranscription.coordinator.presentWindow() }
                }
                .font(.callout)
                .foregroundStyle(WitnessStyle.accent)
                .witnessCard(.accent, padding: 12)
            }
            switch tab {
            case .dictation: dictation
            case .notetaker:
                if hasNotetaker { meeting } else { dictation }
            case .files:
                if let fileTranscription { files(fileTranscription) } else { dictation }
            }
            Divider().overlay(WitnessStyle.line)
            HStack {
                Button { showSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(WitnessStyle.muted)
                Spacer()
                Text("Private by design").foregroundStyle(WitnessStyle.muted)
            }.font(.caption)
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.dictation, title: "Dictation", symbol: "mic")
            if hasNotetaker { tabButton(.notetaker, title: "Notetaker", symbol: "note.text") }
            if fileTranscription != nil { tabButton(.files, title: "Files", symbol: "doc.text") }
        }
        .padding(4)
        .background(WitnessStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 15))
    }

    private func tabButton(_ value: MenuBarTab, title: String, symbol: String) -> some View {
        Button { tab = value } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                if value == .notetaker { NotetakerDemoBadge() }
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .background {
            if tab == value { WitnessControlSurface(cornerRadius: 11) }
        }
        .foregroundStyle(tab == value ? WitnessStyle.ink : WitnessStyle.muted)
        .accessibilityAddTraits(tab == value ? [.isSelected] : [])
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !showsGlobalDictationStatus { compactStatus }
            if coordinator.hasTranscriptionEngine {
                LanguagePinPicker(profile: coordinator.languageProfile, pinned: $coordinator.pinnedLanguage)
                if !coordinator.transcriptionModelState.isReady {
                    ModelStateView(state: coordinator.transcriptionModelState) {
                        Task { await coordinator.prepareTranscriptionModel() }
                    }
                }
            }
            if let result = coordinator.result, !result.isEmpty {
                DisclosureGroup("Last dictation", isExpanded: $showsResult) {
                    ResultView(result: result, prefersRaw: coordinator.prefersRawTranscript,
                        canInsert: coordinator.canInsert && coordinator.hasInsertableResult,
                        insertTitle: insertTitle, insert: { coordinator.insertCurrentResult() })
                }.font(.caption)
            }
            if !coordinator.recentDictations.isEmpty { RecentDictationsView(items: coordinator.recentDictations) }
            modelLabel
        }
    }

    private var compactStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label(presentation.title, systemImage: presentation.systemImage)
                    .font(.callout.weight(.medium)).foregroundStyle(tintColor)
                Spacer(minLength: 0)
                if presentation.showsShortcut, coordinator.isHotkeySelectionReady {
                    Text(verbatim: coordinator.binding.displayString)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).stroke(WitnessStyle.line, lineWidth: 1) }
                        .accessibilityLabel(L10n.format("Shortcut: %@", coordinator.binding.displayString))
                }
            }
            Text(presentation.detail).font(.caption).foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }.padding(.vertical, 4)
    }

    private var showsGlobalDictationStatus: Bool {
        presentation.tint == .warning || coordinator.state.isBusy
    }

    @ViewBuilder private var globalNotices: some View {
        if coordinator.state.isBusy || (tab != .files && showsGlobalDictationStatus) { compactStatus }
        if coordinator.state == .recording || coordinator.state == .finishing {
            RecordingLevelView(snapshot: coordinator.diagnostics.snapshot)
        }
        if tab != .files, coordinator.canOpenReview, let result = coordinator.result, !result.isEmpty {
            Button { coordinator.openReview() } label: {
                Label(reviewTitle(for: result), systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(WitnessSecondaryButtonStyle()).foregroundStyle(WitnessStyle.warning)
        }
        if tab != .files, let outcome = coordinator.lastInsertion, let message = outcome.message { InsertionOutcomeView(message: message) }
        if presentation.showsLicenseAction {
            LicenseLockView(presentation: LicensePresentation(state: coordinator.entitlement), openLicenseSettings: { showSettings(.license) })
        } else if let notice = EntitlementNotice(state: coordinator.entitlement) {
            EntitlementNoticeView(notice: notice, openLicenseSettings: { showSettings(.license) })
        }
        if tab != .files, let warning = coordinator.secureInputWarning {
            SecureInputWarningView(message: warning) { coordinator.refreshAuthorization() }
        }
        if tab != .files, coordinator.needsAccessibilityTrust {
            AccessibilityTrustView(grant: { coordinator.requestAccessibilityTrust() },
                openSettings: { coordinator.openAccessibilitySettings() }, recheck: { coordinator.refreshAccessibilityAuthorization() })
        }
    }

    private func files(_ feature: FileTranscriptionFeature) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                WitnessIconTile(systemImage: "waveform", tint: WitnessStyle.accent)
                Text("Turn a recording into text").font(.title3.weight(.semibold))
                Text("Choose an audio or video file. Witness transcribes it right here on your Mac.")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            Button {
                feature.coordinator.presentWindow()
            } label: {
                Label(
                    LocalizedStringKey(coordinator.isFileTranscriptionRunning ? "View progress" : "Transcribe a file…"),
                    systemImage: coordinator.isFileTranscriptionRunning ? "waveform" : "doc.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(WitnessPrimaryButtonStyle())

            Button { feature.showLibrary() } label: {
                Label("Saved transcripts", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(WitnessStyle.muted)

            modelLabel
        }
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 9) {
                WitnessIconTile(systemImage: "note.text", tint: WitnessStyle.accent)
                Text("A note for every meeting").font(.title3.weight(.semibold))
                Text("Capture a local transcript from your microphone and the meeting app.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.top, 6)
            NotetakerDemoNotice()
            if let item = notetaker.menuBarItem {
                Button(action: item.action) { Label(LocalizedStringKey(item.title), systemImage: item.systemImage).frame(maxWidth: .infinity) }
                    .buttonStyle(WitnessPrimaryButtonStyle())
            }
            if let item = notetaker.historyMenuItem {
                Button(action: item.action) { Label(LocalizedStringKey(item.title), systemImage: item.systemImage) }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(WitnessStyle.muted)
            }
            modelLabel
        }
    }

    private var meetingActivity: some View {
        HStack(spacing: 9) {
            Label(LocalizedStringKey(notetakerStatus.activityTitle), systemImage: notetakerStatus.systemImage ?? "note.text")
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
            if let item = notetaker.stopMenuItem {
                Button("Stop recording", action: item.action).font(.caption).help(LocalizedStringKey(item.title))
            }
            if let item = notetaker.menuBarItem {
                Button("Open", action: item.action).font(.caption)
            }
        }
        .foregroundStyle(notetakerStatus.state == .attention ? WitnessStyle.warning : WitnessStyle.accent)
        .witnessCard(.accent, padding: 12)
    }

    private var modelLabel: some View {
        Button { showSettings(.speechModel) } label: {
            Label(modelSelection.active.title, systemImage: "waveform")
                .font(.caption2).foregroundStyle(WitnessStyle.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).help("Choose a speech model")
    }
    private func showSettings(_ section: SettingsSection? = nil) {
        if let section { SettingsNavigation.request(section) }
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
    private var insertTitle: String {
        guard let target = coordinator.insertionTargetName else { return L10n.string("Insert") }
        return L10n.format("Insert into %@", target)
    }
    private func reviewTitle(for result: DictationResult) -> String {
        switch result.flaggedSpans.count {
        case 0: L10n.string("Check what was marked")
        case 1: L10n.string("Check 1 flagged fragment")
        default: L10n.format("Check %lld flagged fragments", Int64(result.flaggedSpans.count))
        }
    }
    @ViewBuilder private var actions: some View {
        if presentation.showsPermissionRequest {
            Button("Allow microphone access…") { Task { await coordinator.requestMicrophoneAccess() } }.buttonStyle(WitnessPrimaryButtonStyle())
        }
        if presentation.showsSystemSettingsShortcut {
            HStack {
                Button("Open Privacy Settings") { coordinator.openSystemSettings() }.buttonStyle(WitnessPrimaryButtonStyle())
                Button("Re-check") { coordinator.refreshAuthorization() }.buttonStyle(WitnessSecondaryButtonStyle())
            }
        }
        if presentation.showsRecoveryAction {
            Button("Try again") { coordinator.recoverFromFailure() }.buttonStyle(WitnessPrimaryButtonStyle())
        }
    }
    private var tintColor: Color {
        switch presentation.tint {
        case .neutral: WitnessStyle.muted
        case .ready: WitnessStyle.success
        case .active: WitnessStyle.accent
        case .warning: WitnessStyle.warning
        }
    }
}

private struct MeetingSuggestionCard: View {
    let suggestion: NotetakerSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(suggestion.title, systemImage: "video.badge.waveform")
                .font(.headline)
                .foregroundStyle(WitnessStyle.ink)
            Text(suggestion.detail)
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Witness never starts recording automatically and does not notify other participants.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Start note", action: suggestion.start)
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .accessibilityHint("Starts local microphone and meeting audio recording")
                Button("Dismiss", action: suggestion.dismiss)
                    .buttonStyle(WitnessSecondaryButtonStyle())
                    .accessibilityHint("Hides this suggestion and starts its cooldown")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(.accent)
        .accessibilityElement(children: .contain)
    }
}

private struct RecordingLevelView: View {
    let snapshot: CaptureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(Double(snapshot.peakLevel), 1)) {
                Text("Input level")
                    .font(.caption)
            }
            HStack {
                Text(verbatim: L10n.format("%.1f s", snapshot.duration))
                Spacer()
                Text(snapshot.voiceActivity.state.label)
            }
            .font(.caption2)
            .foregroundStyle(WitnessStyle.muted)
        }
        .witnessCard(.accent, padding: 12)
    }
}

/// The selected languages, and the temporary pin over them.
///
/// Through Phase 6 this was a picker over eight combinations, because choosing
/// a combination per dictation was how a mixed profile worked. Since Phase 7
/// the set is chosen once, in Settings, and the only per-session decision left
/// is the narrow one this offers: for now, only this language. A single-language
/// set has nothing to pin, so it says what it is and offers nothing.
private struct LanguagePinPicker: View {
    let profile: LanguageProfile
    @Binding var pinned: SpeechLanguage?

    var body: some View {
        Group {
            if profile.isMixed {
                Picker("Language", selection: $pinned) {
                    Text(verbatim: L10n.format("Any of %@", profile.shortLabel)).tag(SpeechLanguage?.none)
                    ForEach(profile.languages) { language in
                        Text(verbatim: L10n.format("Only %@", language.displayName)).tag(SpeechLanguage?.some(language))
                    }
                }
                .font(.caption)
            } else {
                LabeledContent("Language") {
                    Text(profile.primary.displayName)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct ModelStateView: View {
    let state: TranscriptionModelState
    let prepare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.label)
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)

            switch state {
            case .unavailable, .failed:
                // A retry rather than the first ask: since the app fetches the
                // model at launch, a user who sees this button is looking at a
                // download that did not happen — no network, no disk — and the
                // old "Prepare speech model…" described a step they never had
                // to take.
                Button("Get the speech model", action: prepare)
                    .buttonStyle(WitnessPrimaryButtonStyle())
            case let .preparing(preparation):
                // Determinate where there is a real number, which in practice
                // means the download: a bar that fills is the difference
                // between waiting and wondering.
                if let progress = preparation.progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .ready:
                EmptyView()
            }
        }
        .witnessCard(.neutral, padding: 12)
    }
}

/// Session-only copy history. The list is collapsed until the user asks for it
/// so ten long dictations do not overwhelm the menu bar panel.
struct RecentDictationsView: View {
    let items: [RecentDictation]
    @State private var isExpanded: Bool
    @State private var copiedID: UUID?

    init(items: [RecentDictation], initiallyExpanded: Bool = false) {
        self.items = items
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var listHeight: CGFloat {
        // A ScrollView has no useful intrinsic height in a MenuBarExtra window.
        // A maximum alone therefore collapses to almost zero when it appears.
        // Give each visible row enough room for two text lines and its copy
        // button, then cap the viewport so a long history scrolls.
        min(CGFloat(items.count) * 54, 240)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label("Recent dictations", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(items.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WitnessStyle.muted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WitnessStyle.muted)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? L10n.string("Expanded") : L10n.string("Collapsed"))

            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.text)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(item.text)

                                Button(L10n.string(copiedID == item.id ? "Copied" : "Copy")) {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(item.text, forType: .string)
                                    copiedID = item.id
                                }
                                .buttonStyle(WitnessSecondaryButtonStyle())
                            }
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
        .witnessCard(.neutral, padding: 12)
    }
}

/// The finished result, shown when the risk policy found nothing worth an
/// interruption.
///
/// It is deliberately plain. A review that appears every time is a review
/// nobody reads, so the quiet path has no marks, no strip, and no decision to
/// make — just the text.
///
/// From Phase 4 the text is usually already in the application the user was
/// typing in by the time this is visible. It is still shown, because the menu
/// is where someone looks when the insertion did not go where they expected —
/// and it carries the explicit insert action for users who turned the automatic
/// one off.
private struct ResultView: View {
    let result: DictationResult
    /// Carried out of the review: a user who recovered the raw transcript keeps
    /// it afterwards, rather than having the cleaned text quietly return.
    let prefersRaw: Bool
    let canInsert: Bool
    let insertTitle: String
    let insert: () -> Void

    @State private var didCopy = false

    private var text: String { result.text(preferringRaw: prefersRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: L10n.string(prefersRaw ? "Raw transcript" : "Transcript"))
                    .font(.caption)
                Spacer()
                Text(result.profile.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(WitnessStyle.muted)
            }

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 120)

            HStack {
                Button(L10n.string(didCopy ? "Copied" : "Copy")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    didCopy = true
                }
                .disabled(didCopy)
                .buttonStyle(WitnessSecondaryButtonStyle())

                if canInsert {
                    Button(insertTitle, action: insert)
                        .buttonStyle(WitnessPrimaryButtonStyle())
                }

                Spacer()


            }
        }
        .witnessCard(.neutral)
        .onChange(of: text) { didCopy = false }
    }
}

/// Where the last result went, when it did not go where it was meant to.
///
/// Shown for a clipboard fallback and for a refusal, and never for a successful
/// insertion: the text appearing in the document is the message, and a banner
/// congratulating the app on it would be noise on the path this phase exists to
/// keep quiet.
private struct InsertionOutcomeView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(WitnessStyle.muted)
            Text(message)
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(.neutral, padding: 12)
    }
}

/// The licensing wall, in the one place the user will look when the hotkey
/// stopped doing anything.
///
/// It does not try to sell from inside a menu — the offers and the key field
/// live in Settings, which has room for them. What this has to do is say why
/// nothing happened and point at the door, in two lines, without the user
/// having to guess that a dictation app can be out of trial.
private struct LicenseLockView: View {
    let presentation: LicensePresentation
    let openLicenseSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.headline)
                .font(.caption.weight(.semibold))
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.string(presentation.showsActivation ? "Activate…" : "Open License settings"), action: openLicenseSettings)
                .font(.caption)
                .buttonStyle(WitnessPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(.warning, padding: 12)
    }
}

/// The countdown, in the menu, while the app still works.
///
/// Quieter than the lock it precedes — no coloured background until the last
/// press or the last day — because it is not a refusal. It is the app saying
/// what is about to happen, at the only moment when the user can still do
/// something about it without losing a sentence.
private struct EntitlementNoticeView: View {
    let notice: EntitlementNotice
    let openLicenseSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(notice.headline, systemImage: notice.symbol)
                .font(.caption.weight(.semibold))
            Text(notice.detail)
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button(notice.actionTitle, action: openLicenseSettings)
                .font(.caption)
                .buttonStyle(WitnessSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(notice.isPressing ? .warning : .neutral, padding: 12)
    }
}

/// The one state where the app is working and nothing it does can reach the
/// screen.
///
/// Secure input is process-wide: while it is on, no application may observe or
/// synthesize keyboard events, which is what protects a password field and what
/// makes dictation impossible. The user sees an app that has simply stopped, so
/// the menu — the first place they look — says who is holding it rather than
/// waiting for a refusal to explain it after the next recording.
private struct SecureInputWarningView: View {
    let message: String
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Dictation is blocked right now", systemImage: "lock.laptopcomputer")
                .font(.caption.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Re-check", action: recheck)
                .font(.caption)
                .buttonStyle(WitnessSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(.warning, padding: 12)
    }
}

/// The Accessibility ask.
///
/// Never shown at launch and never blocking: everything the app did before this
/// phase still works without trust, and the text still arrives — on the
/// clipboard. This is an offer to do better, not a wall.
private struct AccessibilityTrustView: View {
    let grant: () -> Void
    let openSettings: () -> Void
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type text for you")
                .font(.caption.weight(.semibold))
            Text("Witness needs Accessibility access to put text into other applications. Without it, results go to the clipboard.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Allow…", action: grant)
                Button("Open Settings", action: openSettings)
                Button("Re-check", action: recheck)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(.neutral, padding: 12)
    }
}
