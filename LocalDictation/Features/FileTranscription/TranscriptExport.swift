import AppKit
import Foundation

/// Renders a stored note into the formats a person takes a transcript away in.
///
/// Every format uses the speaker names as they stand now and the text as it is
/// stored, never the raw recognition. A passage the recognition flagged as
/// uncertain keeps a visible mark in every format that has room for one: a
/// transcript handed to a colleague must not look cleaner than it is.
/// Subtitles are the exception, because a mark there would appear on screen;
/// the library, which is where the note is read, still shows it.
enum MeetingExportRenderer {
    static func displayName(for speakerID: String, in manifest: MeetingManifest) -> String {
        if let name = manifest.speakerDisplayNames[speakerID], !name.isEmpty { return name }
        if speakerID.hasPrefix("speaker-"), let number = speakerID.split(separator: "-").last {
            return "\(L10n.string("Speaker")) \(number)"
        }
        return speakerID
    }

    static func uncertaintyMark() -> String { L10n.string("[check this passage]") }

    static func isUncertain(_ record: MeetingTranscriptRecord) -> Bool { record.recognitionNeedsReview || !record.riskEvidence.isEmpty }

    // MARK: Text formats

    static func text(
        manifest: MeetingManifest,
        records: [MeetingTranscriptRecord],
        notes: MeetingNotes,
        format: MeetingExportFormat
    ) -> String {
        switch format {
        case .plainText:
            let body = records.map { "[\(clock(record: $0))] \(displayName(for: $0.speakerID, in: manifest)): \(marked($0))" }
                .joined(separator: "\n")
            return [manifest.title, body, notes.text.isEmpty ? nil : "Notes\n\(notes.text)"]
                .compactMap { $0 }.joined(separator: "\n\n") + "\n"
        case .markdown:
            let body = records.map { "[\(clock(record: $0))] \(displayName(for: $0.speakerID, in: manifest)): \(marked($0))" }
                .joined(separator: "\n")
            return ["# \(manifest.title)", body, notes.text.isEmpty ? nil : "## Notes\n\n\(notes.text)"]
                .compactMap { $0 }.joined(separator: "\n\n") + "\n"
        case .srt:
            return subtitles(manifest: manifest, records: records)
        case .timestampedText:
            return timestampedText(manifest: manifest, records: records)
        case .docx:
            preconditionFailure("DOCX is binary; use docx(manifest:records:notes:)")
        }
    }

    private static func marked(_ record: MeetingTranscriptRecord) -> String {
        isUncertain(record) ? "\(record.text) \(uncertaintyMark())" : record.text
    }

    private static func clock(record: MeetingTranscriptRecord) -> String {
        let seconds = max(Int(Double(record.startFrame) / max(record.sampleRate, 1)), 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    // MARK: SRT

    /// One cue per two lines of at most 42 characters. A recognised row can be
    /// half a minute long, which no one reads as a single subtitle, so its time
    /// is shared between its cues in proportion to their length.
    static func subtitles(manifest: MeetingManifest, records: [MeetingTranscriptRecord], multipleSpeakers: Bool? = nil) -> String {
        let named = multipleSpeakers ?? (Set(records.map(\.speakerID)).count > 1)
        var cues: [String] = []
        var index = 1
        for record in records {
            let start = Double(record.startFrame) / record.sampleRate
            let end = max(Double(record.endFrame) / record.sampleRate, start + 0.5)
            let prefix = named ? "\(displayName(for: record.speakerID, in: manifest)): " : ""
            let pieces = cueTexts(prefix + record.text)
            let totalCharacters = max(pieces.reduce(0) { $0 + $1.count }, 1)
            var cursor = start
            for piece in pieces {
                let share = (end - start) * Double(piece.count) / Double(totalCharacters)
                let cueEnd = piece == pieces.last ? end : cursor + share
                cues.append("\(index)\n\(srtTime(cursor)) --> \(srtTime(cueEnd))\n\(piece)")
                index += 1
                cursor = cueEnd
            }
        }
        return cues.joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    static func srtTime(_ seconds: Double) -> String {
        let milliseconds = max(Int((seconds * 1000).rounded()), 0)
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60,
                      (milliseconds / 1000) % 60, milliseconds % 1000)
    }

    /// Greedy word wrap into lines of at most 42 characters, two lines a cue.
    static func cueTexts(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > 42, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return stride(from: 0, to: lines.count, by: 2).map { lines[$0..<min($0 + 2, lines.count)].joined(separator: "\n") }
    }

    // MARK: Timestamped text for qualitative-analysis software

    /// `Speaker: #hh:mm:ss-d# text`, one line per turn, with `d` the tenth of a
    /// second. The stamp sits where each turn starts, which is where the
    /// analysis programs that read this syntax expect to find it.
    static func timestampedText(manifest: MeetingManifest, records: [MeetingTranscriptRecord]) -> String {
        let lines = records.map { record -> String in
            let tenths = max(Int((Double(record.startFrame) / record.sampleRate * 10).rounded(.down)), 0)
            let stamp = String(format: "#%02d:%02d:%02d-%d#", tenths / 36_000, (tenths / 600) % 60, (tenths / 10) % 60, tenths % 10)
            return "\(displayName(for: record.speakerID, in: manifest)): \(stamp) \(marked(record))"
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    // MARK: DOCX

    /// A speaker and time line followed by the turn, as a Word document built by
    /// AppKit's own writer, so no dependency is added.
    static func docx(manifest: MeetingManifest, records: [MeetingTranscriptRecord], notes: MeetingNotes) throws -> Data {
        let document = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        let spaced = NSMutableParagraphStyle()
        spaced.paragraphSpacing = 10

        func append(_ string: String, font: NSFont, extra: [NSAttributedString.Key: Any] = [:]) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: spaced]
            attributes.merge(extra) { $1 }
            document.append(NSAttributedString(string: string, attributes: attributes))
        }

        append(manifest.title + "\n", font: .boldSystemFont(ofSize: 18))
        for record in records {
            append("\(displayName(for: record.speakerID, in: manifest))  \(clock(record: record))\n", font: bold)
            append(record.text, font: body, extra: isUncertain(record) ? [.backgroundColor: NSColor.yellow] : [:])
            if isUncertain(record) { append(" \(uncertaintyMark())", font: body, extra: [.backgroundColor: NSColor.yellow]) }
            append("\n", font: body)
        }
        if !notes.text.isEmpty {
            append("\n\(L10n.string("Notes"))\n", font: bold)
            append(notes.text + "\n", font: body)
        }
        let range = NSRange(location: 0, length: document.length)
        return try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}
