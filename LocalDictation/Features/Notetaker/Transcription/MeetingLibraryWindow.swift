import AppKit
import SwiftUI

enum MeetingLibraryPhase: Equatable {
    case loading
    case empty
    case content
    case failed(String)
}

enum MeetingDetailPhase: Equatable {
    case noSelection
    case loading
    case content
    case failed(String)
}

struct MeetingLibraryDetail: Equatable {
    var manifest: MeetingManifest
    var transcript: [MeetingTranscriptRecord]
    var notes: MeetingNotes
}

struct MeetingExportDocument: Equatable {
    let suggestedName: String
    let contents: String
}

@MainActor
final class MeetingLibraryModel: ObservableObject {
    @Published private(set) var meetings: [MeetingManifest] = []
    @Published private(set) var phase: MeetingLibraryPhase = .loading
    @Published private(set) var detailPhase: MeetingDetailPhase = .noSelection
    @Published private(set) var detail: MeetingLibraryDetail?
    @Published private(set) var selectedID: UUID?
    @Published var searchText = ""
    @Published var titleDraft = ""
    @Published var notesDraft = ""
    @Published var speakerNameDrafts: [String: String] = [:]
    @Published private(set) var feedbackMessage: String?
    let loadsOnAppear: Bool

    private let store: any MeetingStoring
    private var listGeneration = UUID()
    private var detailGeneration = UUID()

    init(store: any MeetingStoring) {
        self.store = store
        loadsOnAppear = true
    }

    init(
        previewPhase: MeetingLibraryPhase,
        meetings: [MeetingManifest] = [],
        detail: MeetingLibraryDetail? = nil
    ) {
        store = FileMeetingStore()
        loadsOnAppear = false
        phase = previewPhase
        self.meetings = meetings
        self.detail = detail
        selectedID = detail?.manifest.id
        detailPhase = detail == nil ? .noSelection : .content
        titleDraft = detail?.manifest.title ?? ""
        notesDraft = detail?.notes.text ?? ""
        speakerNameDrafts = Self.editableSpeakerNames(for: detail)
    }

    func refresh(selecting preferredID: UUID? = nil) async {
        let generation = UUID()
        listGeneration = generation
        if meetings.isEmpty { phase = .loading }
        feedbackMessage = nil
        do {
            let results = try await store.search(searchText)
            guard listGeneration == generation else { return }
            meetings = results.map(\.manifest)
            phase = meetings.isEmpty ? .empty : .content
            let nextID = preferredID.flatMap { id in meetings.contains(where: { $0.id == id }) ? id : nil }
                ?? selectedID.flatMap { id in meetings.contains(where: { $0.id == id }) ? id : nil }
                ?? meetings.first?.id
            if let nextID {
                await select(nextID)
            } else {
                clearSelection()
            }
        } catch {
            guard listGeneration == generation else { return }
            meetings = []
            phase = .failed(Self.message(for: error))
            clearSelection()
        }
    }

    func search() async {
        await refresh()
    }

    func select(_ id: UUID) async {
        guard meetings.contains(where: { $0.id == id }) else { return }
        selectedID = id
        detail = nil
        detailPhase = .loading
        feedbackMessage = nil
        let generation = UUID()
        detailGeneration = generation
        do {
            async let manifest = store.loadManifest(id: id)
            async let transcript = store.loadTranscript(meetingID: id)
            async let notes = store.loadNotes(meetingID: id)
            let loaded = try await MeetingLibraryDetail(
                manifest: manifest,
                transcript: transcript,
                notes: notes
            )
            guard detailGeneration == generation, selectedID == id else { return }
            detail = loaded
            titleDraft = loaded.manifest.title
            notesDraft = loaded.notes.text
            speakerNameDrafts = Self.editableSpeakerNames(for: loaded)
            detailPhase = .content
        } catch {
            guard detailGeneration == generation, selectedID == id else { return }
            detailPhase = .failed(Self.message(for: error))
        }
    }

    func saveTitle() async {
        guard var manifest = detail?.manifest else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            feedbackMessage = "Enter a title before saving."
            return
        }
        guard title != manifest.title else { return }
        manifest.title = title
        do {
            try await store.updateManifest(manifest)
            detail?.manifest = manifest
            if let index = meetings.firstIndex(where: { $0.id == manifest.id }) { meetings[index] = manifest }
            feedbackMessage = "Title saved locally."
        } catch {
            feedbackMessage = Self.message(for: error)
        }
    }

    func saveNotes() async {
        guard let id = selectedID else { return }
        let notes = MeetingNotes(text: notesDraft)
        do {
            try await store.saveNotes(notes, meetingID: id)
            detail?.notes = notes
            feedbackMessage = "Notes saved locally."
        } catch {
            feedbackMessage = Self.message(for: error)
        }
    }

    func saveSpeakerNames() async {
        guard var manifest = detail?.manifest else { return }
        var names = manifest.speakerDisplayNames
        for speakerID in Self.editableSpeakerIDs {
            let value = speakerNameDrafts[speakerID, default: Self.defaultSpeakerName(speakerID)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                feedbackMessage = "Speaker labels cannot be empty."
                return
            }
            names[speakerID] = value
        }
        guard names != manifest.speakerDisplayNames else { return }
        manifest.speakerDisplayNames = names
        do {
            try await store.updateManifest(manifest)
            detail?.manifest = manifest
            if let index = meetings.firstIndex(where: { $0.id == manifest.id }) { meetings[index] = manifest }
            feedbackMessage = "Speaker labels saved locally."
        } catch {
            feedbackMessage = Self.message(for: error)
        }
    }

    func resetSpeakerNames() {
        speakerNameDrafts = Dictionary(uniqueKeysWithValues: Self.editableSpeakerIDs.map { ($0, Self.defaultSpeakerName($0)) })
    }

    func assignSpeaker(recordID: UUID, speakerID: String?) async {
        guard let meetingID = selectedID else { return }
        do {
            try await store.reassignTranscript(recordID, meetingID: meetingID, speakerID: speakerID)
            let transcript = try await store.loadTranscript(meetingID: meetingID)
            detail?.transcript = transcript
            feedbackMessage = speakerID == nil ? "Original speaker attribution restored." : "Speaker assignment saved locally."
        } catch {
            feedbackMessage = Self.message(for: error)
        }
    }

    func export(_ format: MeetingExportFormat) async -> MeetingExportDocument? {
        guard let detail else { return nil }
        do {
            let contents = try await store.export(meetingID: detail.manifest.id, format: format)
            let base = Self.safeFilename(detail.manifest.title)
            let suffix = format == .markdown ? "md" : "txt"
            return MeetingExportDocument(suggestedName: "\(base).\(suffix)", contents: contents)
        } catch {
            feedbackMessage = Self.message(for: error)
            return nil
        }
    }

    func reportExportSaved() {
        feedbackMessage = "Export saved."
    }

    func reportExportFailure() {
        feedbackMessage = "The export could not be written. Choose another folder and try again."
    }

    func deleteSelected() async {
        guard let id = selectedID else { return }
        do {
            try await store.deleteMeeting(id: id)
            clearSelection()
            await refresh()
            feedbackMessage = "Meeting note deleted from this Mac."
        } catch {
            feedbackMessage = Self.message(for: error)
        }
    }

    func retryDetail() async {
        guard let selectedID else { return }
        await select(selectedID)
    }

    private func clearSelection() {
        detailGeneration = UUID()
        selectedID = nil
        detail = nil
        titleDraft = ""
        notesDraft = ""
        speakerNameDrafts = [:]
        detailPhase = .noSelection
    }

    private static func safeFilename(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = value.components(separatedBy: disallowed).filter { !$0.isEmpty }
        let value = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Meeting note" : value
    }

    static let editableSpeakerIDs = ["you", "others"] + (1...8).map { "speaker-\($0)" }

    static func defaultSpeakerName(_ speakerID: String) -> String {
        switch speakerID {
        case "you": return "You"
        case "others": return "Others"
        default:
            if let number = speakerID.split(separator: "-").last,
               speakerID.hasPrefix("speaker-"),
               Int(number) != nil {
                return "Speaker \(number)"
            }
            return speakerID
        }
    }

    private static func editableSpeakerNames(for detail: MeetingLibraryDetail?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: editableSpeakerIDs.map { speakerID in
            (speakerID, detail?.manifest.speakerDisplayNames[speakerID] ?? defaultSpeakerName(speakerID))
        })
    }

    private static func message(for error: Error) -> String {
        switch error {
        case MeetingStoreError.corruptManifest, MeetingStoreError.corruptTranscript:
            "This meeting note is damaged. Its other local files have not been changed."
        case MeetingStoreError.unsupportedSchema:
            "This meeting note was created by a newer version of Witness. Update Witness to open it."
        case MeetingStoreError.notFound:
            "This meeting note is no longer available. Refresh the library."
        case MeetingStoreError.unwritable:
            "Witness could not save the change. Check disk space and folder access, then try again."
        default:
            "The local meeting library could not be read. Try again."
        }
    }
}

struct MeetingLibraryView: View {
    @ObservedObject var model: MeetingLibraryModel
    let startMeeting: () -> Void
    @State private var section = MeetingLibrarySection.notes
    @State private var meetingPendingDeletion: MeetingManifest?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 620)
        .witnessWindow()
        .toolbar {
            ToolbarItemGroup {
                Button(action: startMeeting) {
                    Label("Start meeting note", systemImage: "record.circle")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Start a new meeting note")
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh library", systemImage: "arrow.clockwise")
                }
                .help("Refresh the local meeting library")
            }
        }
        .alert(
            "Delete this meeting note?",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { if !$0 { meetingPendingDeletion = nil } }
            ),
            presenting: meetingPendingDeletion
        ) { _ in
            Button("Delete Permanently", role: .destructive) {
                meetingPendingDeletion = nil
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) { meetingPendingDeletion = nil }
        } message: { meeting in
            Text("“\(meeting.title)” and its transcript and notes will be permanently removed from this Mac.")
        }
        .task {
            guard model.loadsOnAppear else { return }
            await model.refresh()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                WitnessBrand(compact: true)
                Spacer()
                Text("MEETING NOTES")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(WitnessStyle.faint)
            }
            .padding(16)
            Divider().overlay(WitnessStyle.line)
            Group {
                switch model.phase {
                case .loading:
                    stateView("Loading meeting notes…", detail: "Reading the private library on this Mac.", symbol: "clock") {
                        ProgressView().controlSize(.small)
                    }
                case .empty:
                    stateView(
                        model.searchText.isEmpty ? "No meeting notes yet" : "No matching meeting notes",
                        detail: model.searchText.isEmpty ? "Start a note when your call begins." : "Try another title or transcript phrase.",
                        symbol: "note.text"
                    ) {
                        if model.searchText.isEmpty {
                            Button("Start meeting note", action: startMeeting)
                                .buttonStyle(WitnessSecondaryButtonStyle())
                        }
                    }
                case let .failed(message):
                    stateView("Library unavailable", detail: message, symbol: "exclamationmark.triangle") {
                        Button("Try Again") { Task { await model.refresh() } }
                            .buttonStyle(WitnessSecondaryButtonStyle())
                    }
                case .content:
                    meetingList
                }
            }
        }
        .background(WitnessStyle.canvas)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search title or transcript")
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.searchText) {
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.search()
            }
        }
    }

    private var meetingList: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { id in if let id { Task { await model.select(id) } } }
        )) {
            ForEach(model.meetings) { meeting in
                MeetingLibraryRow(meeting: meeting)
                    .tag(meeting.id)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Meeting note history")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.detailPhase {
        case .noSelection:
            detailState("Select a meeting note", detail: "Its notes and transcript will appear here.", symbol: "sidebar.left")
        case .loading:
            detailState("Opening meeting note…", detail: "Reading only from this Mac.", symbol: "clock", loading: true)
        case let .failed(message):
            detailState("Meeting unavailable", detail: message, symbol: "exclamationmark.triangle", retry: true)
        case .content:
            if let detail = model.detail { meetingDetail(detail) }
        }
    }

    private func meetingDetail(_ detail: MeetingLibraryDetail) -> some View {
        VStack(spacing: 0) {
            detailHeader(detail)
            Divider().overlay(WitnessStyle.line)
            Picker("Meeting content", selection: $section) {
                ForEach(MeetingLibrarySection.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Group {
                switch section {
                case .notes: notesEditor
                case .transcript: transcript(detail)
                }
            }
            if let feedback = model.feedbackMessage {
                Divider().overlay(WitnessStyle.line)
                Label(feedback, systemImage: feedback.contains("saved") ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Meeting note status: \(feedback)")
            }
        }
        .background(WitnessStyle.raisedSurface.opacity(0.34))
    }

    private func detailHeader(_ detail: MeetingLibraryDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Meeting title", text: $model.titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { Task { await model.saveTitle() } }
                    .accessibilityLabel("Meeting title")
                Button("Save title") { Task { await model.saveTitle() } }
                    .buttonStyle(WitnessSecondaryButtonStyle())
                    .disabled(model.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 10) {
                Label(detail.manifest.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(detail.manifest.completionState.label, systemImage: detail.manifest.completionState.symbol)
                    .foregroundStyle(detail.manifest.completionState == .partial ? WitnessStyle.warning : WitnessStyle.success)
                Spacer()
                Menu {
                    Button("Plain text (.txt)") { export(.plainText) }
                    Button("Markdown (.md)") { export(.markdown) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .help("Export a copy without changing the local note")
                Button(role: .destructive) {
                    meetingPendingDeletion = detail.manifest
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Permanently delete this meeting note")
            }
            .font(.callout)
            if detail.manifest.completionState == .partial {
                Label("Partial transcript — some audio could not be processed. Review uncertain passages before relying on it.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Warning: Partial transcript. Some audio could not be processed.")
            }
        }
        .padding(20)
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your notes").font(.headline)
            TextEditor(text: $model.notesDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius)
                        .stroke(WitnessStyle.line, lineWidth: 1)
                }
                .accessibilityLabel("Meeting notes")
            HStack {
                Text("Saved only on this Mac.")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
                Spacer()
                Button("Save notes") { Task { await model.saveNotes() } }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding([.horizontal, .bottom], 20)
    }

    private func transcript(_ detail: MeetingLibraryDetail) -> some View {
        VStack(spacing: 0) {
            speakerEditor(detail)
            Divider().overlay(WitnessStyle.line)
            ScrollView {
                if detail.transcript.isEmpty {
                    stateView("No transcript was saved", detail: "The meeting may have ended before speech was captured.", symbol: "text.bubble") { EmptyView() }
                        .frame(minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(detail.transcript) { row in
                            MeetingTranscriptRecordView(
                                row: row,
                                speaker: detail.manifest.speakerDisplayNames[row.speakerID] ?? MeetingLibraryModel.defaultSpeakerName(row.speakerID),
                                choices: MeetingLibraryModel.editableSpeakerIDs.map { speakerID in
                                    MeetingSpeakerChoice(
                                        id: speakerID,
                                        name: detail.manifest.speakerDisplayNames[speakerID] ?? MeetingLibraryModel.defaultSpeakerName(speakerID)
                                    )
                                },
                                originalSpeaker: detail.manifest.speakerDisplayNames[row.originalSpeakerID] ?? MeetingLibraryModel.defaultSpeakerName(row.originalSpeakerID),
                                assign: { speakerID in Task { await model.assignSpeaker(recordID: row.id, speakerID: speakerID) } },
                                restore: { Task { await model.assignSpeaker(recordID: row.id, speakerID: nil) } }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func speakerEditor(_ detail: MeetingLibraryDetail) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Automatic numbered speakers remain off until the local corpus quality gate passes. You can label passages manually; the original attribution is always retained.")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(MeetingLibraryModel.editableSpeakerIDs, id: \.self) { speakerID in
                    HStack {
                        Text(MeetingLibraryModel.defaultSpeakerName(speakerID))
                            .font(.caption.weight(.medium))
                            .frame(width: 72, alignment: .leading)
                        TextField(
                            MeetingLibraryModel.defaultSpeakerName(speakerID),
                            text: Binding(
                                get: { model.speakerNameDrafts[speakerID, default: MeetingLibraryModel.defaultSpeakerName(speakerID)] },
                                set: { model.speakerNameDrafts[speakerID] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Display name for \(MeetingLibraryModel.defaultSpeakerName(speakerID))")
                    }
                }
                HStack {
                    Button("Reset labels") { model.resetSpeakerNames() }
                        .buttonStyle(WitnessSecondaryButtonStyle())
                    Spacer()
                    Button("Save labels") { Task { await model.saveSpeakerNames() } }
                        .buttonStyle(WitnessPrimaryButtonStyle())
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Speaker labels", systemImage: "person.2")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityHint("Expands controls for renaming You, Others, and numbered speakers")
    }

    private func export(_ format: MeetingExportFormat) {
        Task {
            guard let document = await model.export(format) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.suggestedName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try document.contents.write(to: url, atomically: true, encoding: .utf8)
                model.reportExportSaved()
            } catch {
                model.reportExportFailure()
            }
        }
    }

    private func detailState(_ title: String, detail: String, symbol: String, loading: Bool = false, retry: Bool = false) -> some View {
        stateView(title, detail: detail, symbol: symbol) {
            if loading { ProgressView().controlSize(.small) }
            if retry {
                Button("Try Again") { Task { await model.retryDetail() } }
                    .buttonStyle(WitnessSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WitnessStyle.raisedSurface.opacity(0.34))
    }

    private func stateView<Actions: View>(
        _ title: String,
        detail: String,
        symbol: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(WitnessStyle.faint)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private enum MeetingLibrarySection: String, CaseIterable, Identifiable {
    case notes
    case transcript

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct MeetingLibraryRow: View {
    let meeting: MeetingManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: meeting.completionState.symbol).accessibilityHidden(true)
                Text(meeting.completionState.label)
                Text("·")
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(meeting.completionState == .partial ? WitnessStyle.warning : WitnessStyle.muted)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meeting.title), \(meeting.completionState.label), \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct MeetingSpeakerChoice: Identifiable {
    let id: String
    let name: String
}

private struct MeetingTranscriptRecordView: View {
    let row: MeetingTranscriptRecord
    let speaker: String
    let choices: [MeetingSpeakerChoice]
    let originalSpeaker: String
    let assign: (String) -> Void
    let restore: () -> Void

    private var timestamp: String {
        let seconds = max(Int(Double(row.startFrame) / max(row.sampleRate, 1)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var needsReview: Bool {
        row.recognitionNeedsReview || !row.riskEvidence.isEmpty || row.rawText != row.text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(WitnessStyle.faint)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Menu {
                        ForEach(choices) { choice in
                            Button {
                                assign(choice.id)
                            } label: {
                                if choice.id == row.speakerID {
                                    Label(choice.name, systemImage: "checkmark")
                                } else {
                                    Text(choice.name)
                                }
                            }
                        }
                        if row.isManuallyReassigned {
                            Divider()
                            Button("Restore original: \(originalSpeaker)", action: restore)
                        }
                    } label: {
                        Label(speaker, systemImage: "person.crop.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Speaker: \(speaker)")
                    .accessibilityHint("Choose a different speaker for this passage")
                    if row.speakerAssignmentSource == .diarization, let confidence = row.speakerConfidence {
                        Text("Inferred \(confidence.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.caption2)
                            .foregroundStyle(WitnessStyle.muted)
                            .accessibilityLabel("Inferred speaker confidence \(confidence.formatted(.percent))")
                    } else if row.isManuallyReassigned {
                        Text("Edited · original \(originalSpeaker)")
                            .font(.caption2)
                            .foregroundStyle(WitnessStyle.muted)
                    }
                    if needsReview {
                        Label(row.recognitionNeedsReview ? "Low confidence" : "Review",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WitnessStyle.warning)
                    }
                }
                Text(row.recognitionNeedsReview ? "Model guess: \(row.text)" : row.text)
                    .font(.body)
                    .foregroundStyle(row.recognitionNeedsReview ? WitnessStyle.muted : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if row.rawText != row.text {
                    Text("Recognized: \(row.rawText)")
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius)
                .stroke(needsReview ? WitnessStyle.warning.opacity(0.5) : WitnessStyle.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private extension MeetingCompletionState {
    var label: String {
        switch self {
        case .recording: "Recording"
        case .completed: "Complete"
        case .partial: "Partial"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "record.circle"
        case .completed: "checkmark.circle"
        case .partial: "exclamationmark.triangle"
        }
    }
}

@MainActor
final class MeetingLibraryWindowController: NSObject {
    let model: MeetingLibraryModel
    private let startMeeting: () -> Void
    private var window: NSWindow?

    init(model: MeetingLibraryModel, startMeeting: @escaping () -> Void) {
        self.model = model
        self.startMeeting = startMeeting
    }

    func show(selecting meetingID: UUID? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.refresh(selecting: meetingID) }
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Witness Meeting Notes — Test Build"
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MeetingLibraryView(model: model, startMeeting: startMeeting))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#if DEBUG
private enum MeetingLibraryPreviews {
    static let partialManifest = MeetingManifest(
        title: "Zoom technical test",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        endedAt: Date(timeIntervalSince1970: 1_800_003_600),
        selectedLanguages: [.english],
        sourcePlatform: .manual,
        completionState: .partial
    )

    static let partialDetail = MeetingLibraryDetail(
        manifest: partialManifest,
        transcript: [
            MeetingTranscriptRecord(
                source: .microphone,
                speakerID: "you",
                startFrame: 0,
                endFrame: 16_000,
                text: "Let's verify the local transcript.",
                rawText: "Lets verify the local transcript",
                meanConfidence: 0.72,
                minimumConfidence: 0.51,
                hasConfidenceSignal: true,
                riskEvidence: ["low confidence"]
            )
        ],
        notes: MeetingNotes(text: "Check both audio sources before the long run.")
    )
}

extension MeetingLibraryModel {
    static func partialPreview() -> MeetingLibraryModel {
        MeetingLibraryModel(
            previewPhase: .content,
            meetings: [MeetingLibraryPreviews.partialManifest],
            detail: MeetingLibraryPreviews.partialDetail
        )
    }
}

#Preview("Meeting library — empty") {
    MeetingLibraryView(model: MeetingLibraryModel(previewPhase: .empty), startMeeting: {})
}

#Preview("Meeting library — loading") {
    MeetingLibraryView(model: MeetingLibraryModel(previewPhase: .loading), startMeeting: {})
}

#Preview("Meeting library — partial") {
    MeetingLibraryView(
        model: .partialPreview(),
        startMeeting: {}
    )
}

#Preview("Meeting library — unavailable") {
    MeetingLibraryView(
        model: MeetingLibraryModel(previewPhase: .failed("The selected local speech model is unavailable. Prepare it in Witness and try again.")),
        startMeeting: {}
    )
}

#Preview("Meeting library — error") {
    MeetingLibraryView(
        model: MeetingLibraryModel(previewPhase: .failed("The local meeting library could not be read. Try again.")),
        startMeeting: {}
    )
}
#endif
