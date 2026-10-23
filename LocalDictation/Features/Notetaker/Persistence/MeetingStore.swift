import Foundation

enum MeetingCompletionState: String, Codable, Sendable, Equatable {
    case recording
    case completed
    case partial
}

struct MeetingManifest: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    let selectedLanguages: [SpeechLanguage]
    let sourcePlatform: MeetingPlatform
    var completionState: MeetingCompletionState
    var speakerDisplayNames: [String: String]
    /// Content-free local diagnostic categories for a partial note. Optional
    /// keeps schema-1 manifests written by earlier test builds readable.
    var partialIssueCodes: [String]?

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        selectedLanguages: [SpeechLanguage],
        sourcePlatform: MeetingPlatform,
        completionState: MeetingCompletionState = .recording,
        speakerDisplayNames: [String: String] = ["you": "You", "others": "Others"],
        partialIssueCodes: [String]? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.selectedLanguages = selectedLanguages
        self.sourcePlatform = sourcePlatform
        self.completionState = completionState
        self.speakerDisplayNames = speakerDisplayNames
        self.partialIssueCodes = partialIssueCodes
    }
}

struct MeetingTranscriptRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let source: MeetingAudioSource
    var speakerID: String
    let originalSpeakerID: String
    var speakerConfidence: Double?
    var speakerAssignmentSource: SpeakerAssignmentSource
    let originalSpeakerConfidence: Double?
    let originalSpeakerAssignmentSource: SpeakerAssignmentSource
    let wordAttributions: [SpeakerWordAttribution]
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    let text: String
    let rawText: String
    let meanConfidence: Double?
    let minimumConfidence: Double?
    let hasConfidenceSignal: Bool
    let riskEvidence: [String]

    init(
        id: UUID = UUID(),
        source: MeetingAudioSource,
        speakerID: String,
        originalSpeakerID: String? = nil,
        speakerConfidence: Double? = nil,
        speakerAssignmentSource: SpeakerAssignmentSource = .sourceFallback,
        originalSpeakerConfidence: Double? = nil,
        originalSpeakerAssignmentSource: SpeakerAssignmentSource? = nil,
        wordAttributions: [SpeakerWordAttribution] = [],
        startFrame: Int64,
        endFrame: Int64,
        sampleRate: Double = 16_000,
        text: String,
        rawText: String? = nil,
        meanConfidence: Double?,
        minimumConfidence: Double?,
        hasConfidenceSignal: Bool,
        riskEvidence: [String] = []
    ) {
        self.id = id
        self.source = source
        self.speakerID = speakerID
        self.originalSpeakerID = originalSpeakerID ?? speakerID
        self.speakerConfidence = speakerConfidence
        self.speakerAssignmentSource = speakerAssignmentSource
        self.originalSpeakerConfidence = originalSpeakerConfidence ?? speakerConfidence
        self.originalSpeakerAssignmentSource = originalSpeakerAssignmentSource ?? speakerAssignmentSource
        self.wordAttributions = wordAttributions
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.sampleRate = sampleRate
        self.text = text
        self.rawText = rawText ?? text
        self.meanConfidence = meanConfidence
        self.minimumConfidence = minimumConfidence
        self.hasConfidenceSignal = hasConfidenceSignal
        self.riskEvidence = riskEvidence
    }

    init(row: MeetingTranscriptRow) {
        self.init(
            source: row.source,
            speakerID: row.speakerID,
            speakerConfidence: row.speakerConfidence,
            speakerAssignmentSource: row.speakerAssignmentSource,
            wordAttributions: row.wordAttributions,
            startFrame: row.startFrame,
            endFrame: row.endFrame,
            text: row.text,
            rawText: row.original.text,
            meanConfidence: row.original.meanConfidence,
            minimumConfidence: row.original.minimumConfidence,
            hasConfidenceSignal: row.original.hasConfidenceSignal,
            riskEvidence: row.recognitionNeedsReview ? ["low-confidence recognition"] : []
        )
    }

    init(row: MeetingTranscriptRow, alignment: SpeakerAlignment) {
        self.init(
            source: row.source,
            speakerID: alignment.speakerID,
            speakerConfidence: alignment.confidence,
            speakerAssignmentSource: .diarization,
            wordAttributions: alignment.words,
            startFrame: row.startFrame,
            endFrame: row.endFrame,
            text: row.text,
            rawText: row.original.text,
            meanConfidence: row.original.meanConfidence,
            minimumConfidence: row.original.minimumConfidence,
            hasConfidenceSignal: row.original.hasConfidenceSignal,
            riskEvidence: row.recognitionNeedsReview ? ["low-confidence recognition"] : []
        )
    }

    var recognitionNeedsReview: Bool {
        MeetingRecognitionQualityPolicy.needsReview(
            meanConfidence: meanConfidence,
            hasConfidenceSignal: hasConfidenceSignal
        )
    }

    var isManuallyReassigned: Bool {
        speakerAssignmentSource == .manual && speakerID != originalSpeakerID
    }

    func assigningSpeaker(_ newSpeakerID: String?) -> MeetingTranscriptRecord {
        if newSpeakerID == speakerID { return self }
        var copy = self
        if let newSpeakerID {
            copy.speakerID = newSpeakerID
            copy.speakerConfidence = nil
            copy.speakerAssignmentSource = .manual
        } else {
            copy.speakerID = originalSpeakerID
            copy.speakerConfidence = originalSpeakerConfidence
            copy.speakerAssignmentSource = originalSpeakerAssignmentSource
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, speakerID, originalSpeakerID, speakerConfidence, speakerAssignmentSource
        case originalSpeakerConfidence, originalSpeakerAssignmentSource, wordAttributions
        case startFrame, endFrame, sampleRate, text, rawText, meanConfidence, minimumConfidence
        case hasConfidenceSignal, riskEvidence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(MeetingAudioSource.self, forKey: .source)
        speakerID = try values.decode(String.self, forKey: .speakerID)
        originalSpeakerID = try values.decodeIfPresent(String.self, forKey: .originalSpeakerID) ?? speakerID
        speakerConfidence = try values.decodeIfPresent(Double.self, forKey: .speakerConfidence)
        speakerAssignmentSource = try values.decodeIfPresent(SpeakerAssignmentSource.self, forKey: .speakerAssignmentSource) ?? .sourceFallback
        originalSpeakerConfidence = try values.decodeIfPresent(Double.self, forKey: .originalSpeakerConfidence) ?? speakerConfidence
        originalSpeakerAssignmentSource = try values.decodeIfPresent(SpeakerAssignmentSource.self, forKey: .originalSpeakerAssignmentSource) ?? speakerAssignmentSource
        wordAttributions = try values.decodeIfPresent([SpeakerWordAttribution].self, forKey: .wordAttributions) ?? []
        startFrame = try values.decode(Int64.self, forKey: .startFrame)
        endFrame = try values.decode(Int64.self, forKey: .endFrame)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        text = try values.decode(String.self, forKey: .text)
        rawText = try values.decode(String.self, forKey: .rawText)
        meanConfidence = try values.decodeIfPresent(Double.self, forKey: .meanConfidence)
        minimumConfidence = try values.decodeIfPresent(Double.self, forKey: .minimumConfidence)
        hasConfidenceSignal = try values.decode(Bool.self, forKey: .hasConfidenceSignal)
        riskEvidence = try values.decode([String].self, forKey: .riskEvidence)
    }
}

struct MeetingNotes: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var text: String

    init(text: String = "") {
        schemaVersion = Self.currentSchemaVersion
        self.text = text
    }
}

struct MeetingSearchResult: Sendable, Equatable {
    let manifest: MeetingManifest
    let matchingTranscriptIDs: [UUID]
}

enum MeetingExportFormat: Sendable, Equatable {
    case plainText
    case markdown
}

enum MeetingStoreError: Error, Sendable, Equatable {
    case alreadyExists(UUID)
    case notFound(UUID)
    case unsupportedSchema(Int)
    case corruptManifest(UUID)
    case corruptTranscript(UUID, line: Int)
    case unreadable(String)
    case unwritable(String)
}

protocol MeetingStoring: Sendable {
    func createMeeting(_ manifest: MeetingManifest) async throws
    func loadManifest(id: UUID) async throws -> MeetingManifest
    func updateManifest(_ manifest: MeetingManifest) async throws
    func appendTranscript(_ record: MeetingTranscriptRecord, meetingID: UUID) async throws
    func replaceTranscript(_ records: [MeetingTranscriptRecord], meetingID: UUID) async throws
    func loadTranscript(meetingID: UUID) async throws -> [MeetingTranscriptRecord]
    func reassignTranscript(_ recordID: UUID, meetingID: UUID, speakerID: String?) async throws
    func loadNotes(meetingID: UUID) async throws -> MeetingNotes
    func saveNotes(_ notes: MeetingNotes, meetingID: UUID) async throws
    func listMeetings() async throws -> [MeetingManifest]
    func search(_ query: String) async throws -> [MeetingSearchResult]
    func export(meetingID: UUID, format: MeetingExportFormat) async throws -> String
    func deleteMeeting(id: UUID) async throws
}

/// Actor-isolated, dependency-free meeting persistence. It creates no directory
/// until `createMeeting` follows an explicit user start action.
actor FileMeetingStore: MeetingStoring {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void
    typealias AppendWriter = @Sendable (Data, URL) throws -> Void

    let rootURL: URL
    private let fileManager: FileManager
    private let atomicWriter: AtomicWriter
    private let appendWriter: AppendWriter
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        rootURL: URL = ApplicationSupportDirectory.subdirectory("Meetings"),
        fileManager: FileManager = .default,
        atomicWriter: AtomicWriter? = nil,
        appendWriter: AppendWriter? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter ?? { data, url in
            try data.write(to: url, options: .atomic)
        }
        self.appendWriter = appendWriter ?? { data, url in
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    func createMeeting(_ manifest: MeetingManifest) throws {
        guard manifest.schemaVersion == MeetingManifest.currentSchemaVersion else {
            throw MeetingStoreError.unsupportedSchema(manifest.schemaVersion)
        }
        let directory = meetingDirectory(manifest.id)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw MeetingStoreError.alreadyExists(manifest.id)
        }
        do {
            try secureDirectory(rootURL)
            try secureDirectory(directory)
            try writeAtomic(manifest, to: directory.appendingPathComponent("manifest.json"))
            try writeAtomic(MeetingNotes(), to: directory.appendingPathComponent("notes.json"))
            try Data().write(to: directory.appendingPathComponent("transcript.ndjson"), options: .atomic)
            try secureFile(directory.appendingPathComponent("transcript.ndjson"))
        } catch let error as MeetingStoreError {
            try? fileManager.removeItem(at: directory)
            throw error
        } catch {
            try? fileManager.removeItem(at: directory)
            throw MeetingStoreError.unwritable("createMeeting")
        }
    }

    func loadManifest(id: UUID) throws -> MeetingManifest {
        let url = meetingDirectory(id).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { throw MeetingStoreError.notFound(id) }
        do {
            let manifest = try decoder.decode(MeetingManifest.self, from: Data(contentsOf: url))
            guard manifest.id == id else { throw MeetingStoreError.corruptManifest(id) }
            guard manifest.schemaVersion <= MeetingManifest.currentSchemaVersion else {
                throw MeetingStoreError.unsupportedSchema(manifest.schemaVersion)
            }
            return manifest
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.corruptManifest(id)
        }
    }

    func updateManifest(_ manifest: MeetingManifest) throws {
        guard fileManager.fileExists(atPath: meetingDirectory(manifest.id).path) else {
            throw MeetingStoreError.notFound(manifest.id)
        }
        try writeAtomic(manifest, to: meetingDirectory(manifest.id).appendingPathComponent("manifest.json"))
    }

    func appendTranscript(_ record: MeetingTranscriptRecord, meetingID: UUID) throws {
        let url = meetingDirectory(meetingID).appendingPathComponent("transcript.ndjson")
        guard fileManager.fileExists(atPath: url.path) else { throw MeetingStoreError.notFound(meetingID) }
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            try appendWriter(data, url)
            try secureFile(url)
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.unwritable("appendTranscript")
        }
    }

    func replaceTranscript(_ records: [MeetingTranscriptRecord], meetingID: UUID) throws {
        try writeTranscript(records, meetingID: meetingID, operation: "replaceTranscript")
    }

    private func writeTranscript(
        _ records: [MeetingTranscriptRecord],
        meetingID: UUID,
        operation: String
    ) throws {
        let url = meetingDirectory(meetingID).appendingPathComponent("transcript.ndjson")
        guard fileManager.fileExists(atPath: url.path) else { throw MeetingStoreError.notFound(meetingID) }
        do {
            var data = Data()
            for record in records {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try atomicWriter(data, url)
            try secureFile(url)
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.unwritable(operation)
        }
    }

    func loadTranscript(meetingID: UUID) throws -> [MeetingTranscriptRecord] {
        let url = meetingDirectory(meetingID).appendingPathComponent("transcript.ndjson")
        guard fileManager.fileExists(atPath: url.path) else { throw MeetingStoreError.notFound(meetingID) }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return [] }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if data.last != 0x0A { lines.removeLast() } // a crash may tear only the final line
            if lines.last?.isEmpty == true { lines.removeLast() }
            return try lines.enumerated().map { offset, line in
                do { return try decoder.decode(MeetingTranscriptRecord.self, from: Data(line)) }
                catch { throw MeetingStoreError.corruptTranscript(meetingID, line: offset + 1) }
            }
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.unreadable("loadTranscript")
        }
    }

    func reassignTranscript(_ recordID: UUID, meetingID: UUID, speakerID: String?) throws {
        var records = try loadTranscript(meetingID: meetingID)
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            throw MeetingStoreError.notFound(recordID)
        }
        records[index] = records[index].assigningSpeaker(speakerID)
        try writeTranscript(records, meetingID: meetingID, operation: "rewriteTranscript")
    }

    func loadNotes(meetingID: UUID) throws -> MeetingNotes {
        let url = meetingDirectory(meetingID).appendingPathComponent("notes.json")
        guard fileManager.fileExists(atPath: url.path) else { throw MeetingStoreError.notFound(meetingID) }
        do {
            let notes = try decoder.decode(MeetingNotes.self, from: Data(contentsOf: url))
            guard notes.schemaVersion <= MeetingNotes.currentSchemaVersion else {
                throw MeetingStoreError.unsupportedSchema(notes.schemaVersion)
            }
            return notes
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.unreadable("loadNotes")
        }
    }

    func saveNotes(_ notes: MeetingNotes, meetingID: UUID) throws {
        guard fileManager.fileExists(atPath: meetingDirectory(meetingID).path) else {
            throw MeetingStoreError.notFound(meetingID)
        }
        try writeAtomic(notes, to: meetingDirectory(meetingID).appendingPathComponent("notes.json"))
    }

    func listMeetings() throws -> [MeetingManifest] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try loadManifest(id: id)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func search(_ query: String) throws -> [MeetingSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return try listMeetings().map { MeetingSearchResult(manifest: $0, matchingTranscriptIDs: []) }
        }
        var results: [MeetingSearchResult] = []
        for manifest in try listMeetings() {
            let rows = try loadTranscript(meetingID: manifest.id)
            let matches = rows.filter { $0.text.localizedCaseInsensitiveContains(needle) }.map(\.id)
            if manifest.title.localizedCaseInsensitiveContains(needle) || !matches.isEmpty {
                results.append(MeetingSearchResult(manifest: manifest, matchingTranscriptIDs: matches))
            }
        }
        return results
    }

    func export(meetingID: UUID, format: MeetingExportFormat) throws -> String {
        let manifest = try loadManifest(id: meetingID)
        let rows = try loadTranscript(meetingID: meetingID)
        let notes = try loadNotes(meetingID: meetingID)
        let body = rows.map { row in
            "[\(Self.timestamp(frame: row.startFrame, sampleRate: row.sampleRate))] \(manifest.speakerDisplayNames[row.speakerID] ?? row.speakerID): \(row.text)"
        }.joined(separator: "\n")
        switch format {
        case .plainText:
            return [manifest.title, body, notes.text.isEmpty ? nil : "Notes\n\(notes.text)"]
                .compactMap { $0 }.joined(separator: "\n\n") + "\n"
        case .markdown:
            return ["# \(manifest.title)", body, notes.text.isEmpty ? nil : "## Notes\n\n\(notes.text)"]
                .compactMap { $0 }.joined(separator: "\n\n") + "\n"
        }
    }

    func deleteMeeting(id: UUID) throws {
        let directory = meetingDirectory(id)
        guard fileManager.fileExists(atPath: directory.path) else { throw MeetingStoreError.notFound(id) }
        do { try fileManager.removeItem(at: directory) }
        catch { throw MeetingStoreError.unwritable("deleteMeeting") }
    }

    private func meetingDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func secureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private func secureFile(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private func writeAtomic<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try atomicWriter(try encoder.encode(value), url)
            try secureFile(url)
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.unwritable("atomicWrite")
        }
    }

    private static func timestamp(frame: Int64, sampleRate: Double) -> String {
        let seconds = max(Int(Double(frame) / max(sampleRate, 1)), 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
