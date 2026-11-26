import Foundation

/// Connects a live in-memory transcript to append-only storage without making
/// capture or transcription depend on file I/O details.
actor MeetingPersistenceRecorder {
    private let store: any MeetingStoring
    private var manifest: MeetingManifest?
    private var recoveryWindows: Set<MeetingTranscriptWindowKey> = []

    init(store: any MeetingStoring = FileMeetingStore()) {
        self.store = store
    }

    var meetingID: UUID? { manifest?.id }

    @discardableResult
    func begin(title: String, profile: LanguageProfile, platform: MeetingPlatform = .manual, at date: Date = Date()) async throws -> UUID {
        precondition(manifest == nil, "A recorder owns at most one meeting")
        let manifest = MeetingManifest(
            title: title,
            startedAt: date,
            selectedLanguages: profile.languages,
            sourcePlatform: platform
        )
        try await store.createMeeting(manifest)
        self.manifest = manifest
        return manifest.id
    }

    func persist(rows: [MeetingTranscriptRow]) async throws {
        guard let manifest else { return }
        for row in rows where !recoveryWindows.contains(MeetingTranscriptWindowKey(row)) {
            try await store.appendTranscript(MeetingTranscriptRecord(row: row), meetingID: manifest.id)
            recoveryWindows.insert(MeetingTranscriptWindowKey(row))
        }
    }

    /// Reconciles delayed local speaker hypotheses after the diarizer flushes
    /// its final context. The recognized text is unchanged and the file swap is
    /// atomic, while live append-only writes still provide crash recovery.
    func replace(rows: [MeetingTranscriptRow]) async throws {
        guard let manifest else { return }
        try await store.replaceTranscript(
            rows.map(MeetingTranscriptRecord.init(row:)),
            meetingID: manifest.id
        )
        recoveryWindows = Set(rows.map(MeetingTranscriptWindowKey.init))
    }

    func finish(partial: Bool, issueCodes: [String] = [], at date: Date = Date()) async throws {
        guard var manifest else { return }
        manifest.endedAt = date
        manifest.completionState = partial ? .partial : .completed
        manifest.partialIssueCodes = partial && !issueCodes.isEmpty ? issueCodes : nil
        try await store.updateManifest(manifest)
        self.manifest = manifest
    }

    /// Publishes the completed file transcript in one local store operation.
    func saveFile(
        title: String,
        profile: LanguageProfile,
        source: MeetingSourceFile?,
        rows: [MeetingTranscriptRow]
    ) async throws -> UUID {
        let date = Date()
        let manifest = MeetingManifest(
            title: title,
            startedAt: date,
            endedAt: date,
            selectedLanguages: profile.languages,
            sourcePlatform: .file,
            completionState: .completed,
            speakerDisplayNames: ["others": L10n.string("Speaker")],
            sourceFile: source
        )
        try await store.createMeeting(manifest, transcript: rows.map(MeetingTranscriptRecord.init(row:)))
        return manifest.id
    }

    func discardEmptyMeeting() async {
        guard let manifest, recoveryWindows.isEmpty else { return }
        try? await store.deleteMeeting(id: manifest.id)
        self.manifest = nil
    }
}
