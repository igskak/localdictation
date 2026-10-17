import Foundation

struct CleanupReplacement: Sendable, Equatable {
    let range: Range<Int>
    let text: String
    let kind: TextEdit.Kind
    var typedValue: TypedValueRecord? = nil
}

enum CleanupTransformation {
    static func apply(
        _ replacements: [CleanupReplacement],
        to raw: String,
        language: SpeechLanguage
    ) -> CleanupResult {
        let source = Array(raw)
        let ordered = replacements.sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
            return $0.text.count > $1.text.count
        }
        var accepted: [CleanupReplacement] = []
        for replacement in ordered {
            guard replacement.range.lowerBound >= 0,
                  replacement.range.upperBound <= source.count,
                  String(source[replacement.range]) != replacement.text,
                  !accepted.contains(where: { $0.range.overlaps(replacement.range) || $0.range == replacement.range })
            else { continue }
            accepted.append(replacement)
        }
        guard !accepted.isEmpty else { return .unchanged(raw, language: language) }

        var output = ""
        var segments: [EditMap.Segment] = []
        var edits: [TextEdit] = []
        var rawCursor = 0
        var cleanCursor = 0
        for replacement in accepted {
            if rawCursor < replacement.range.lowerBound {
                let carried = rawCursor..<replacement.range.lowerBound
                let text = String(source[carried])
                output += text
                segments.append(.init(raw: carried, cleaned: cleanCursor..<(cleanCursor + text.count), isEdit: false))
                cleanCursor += text.count
            }
            let cleanRange = cleanCursor..<(cleanCursor + replacement.text.count)
            output += replacement.text
            segments.append(.init(raw: replacement.range, cleaned: cleanRange, isEdit: true))
            edits.append(
                TextEdit(
                    kind: replacement.kind,
                    rawRange: replacement.range,
                    cleanedRange: cleanRange,
                    rawText: String(source[replacement.range]),
                    cleanedText: replacement.text,
                    typedValue: replacement.typedValue
                )
            )
            rawCursor = replacement.range.upperBound
            cleanCursor = cleanRange.upperBound
        }
        if rawCursor < source.count {
            let carried = rawCursor..<source.count
            let text = String(source[carried])
            output += text
            segments.append(.init(raw: carried, cleaned: cleanCursor..<(cleanCursor + text.count), isEdit: false))
            cleanCursor += text.count
        }
        return CleanupResult(
            raw: raw,
            cleaned: output,
            edits: edits,
            map: EditMap(segments: segments, rawLength: source.count, cleanedLength: cleanCursor),
            language: language
        )
    }
}
