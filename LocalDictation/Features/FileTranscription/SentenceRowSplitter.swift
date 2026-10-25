import Foundation

/// Cuts a recognised window into rows a person can read as turns.
///
/// A file is recognised in windows of 15-28 seconds, so a row was one
/// paragraph of that length. The words are timed, so the window can be cut at
/// the end of a sentence without inventing a time: each part starts at its first
/// word and ends at its last. Parts are grown to at least `targetSeconds`, so a
/// sentence of three words does not become a row of its own.
///
/// A window whose shown text is not exactly what the engine returned (overlap
/// repair removed words) is left alone: its tokens no longer line up with it.
struct SentenceRowSplitter: Sendable {
    var minimumRowSeconds = 8.0
    var targetSeconds = 6.0
    static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。"]

    func split(_ rows: [MeetingTranscriptRow], sampleRate: Double = 16_000) -> [MeetingTranscriptRow] {
        rows.flatMap { split($0, sampleRate: sampleRate) }
    }

    func split(_ row: MeetingTranscriptRow, sampleRate: Double = 16_000) -> [MeetingTranscriptRow] {
        let length = Double(row.endFrame - row.startFrame) / sampleRate
        let text = row.original.text
        let tokens = row.original.tokens
        guard length >= minimumRowSeconds, row.text == text, !tokens.isEmpty else { return [row] }
        let characters = Array(text)
        guard tokens.allSatisfy({ $0.range.lowerBound >= 0 && $0.range.upperBound <= characters.count && $0.range.lowerBound < $0.range.upperBound }) else {
            return [row]
        }

        var groups: [[TranscriptToken]] = []
        var current: [TranscriptToken] = []
        for token in tokens {
            current.append(token)
            let ends = characters[token.range].last.map(Self.sentenceEnds.contains) ?? false
            if ends, let first = current.first, token.end - first.start >= targetSeconds {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            // A short tail joins the last group instead of becoming a stub.
            let tailSeconds = (current.last?.end ?? 0) - (current.first?.start ?? 0)
            if let last = groups.last, tailSeconds < targetSeconds / 2 {
                groups[groups.count - 1] = last + current
            } else {
                groups.append(current)
            }
        }
        guard groups.count > 1 else { return [row] }

        return groups.enumerated().compactMap { index, group in
            guard let first = group.first, let last = group.last else { return nil }
            let lower = index == 0 ? 0 : first.range.lowerBound
            let nextLower = groups.indices.contains(index + 1) ? groups[index + 1][0].range.lowerBound : characters.count
            let upper = min(max(nextLower, lower), characters.count)
            let slice = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slice.isEmpty else { return nil }
            let start = row.startFrame + Int64((max(first.start, 0) * sampleRate).rounded())
            let end = row.startFrame + Int64((max(last.end, last.start) * sampleRate).rounded())
            return MeetingTranscriptRow(
                source: row.source,
                startFrame: index == 0 ? row.startFrame : start,
                endFrame: index == groups.count - 1 ? row.endFrame : max(end, start + 1),
                text: slice,
                original: row.original,
                speakerID: row.speakerID,
                speakerConfidence: row.speakerConfidence,
                speakerAssignmentSource: row.speakerAssignmentSource,
                wordAttributions: [],
                rawSlice: slice
            )
        }
    }
}
