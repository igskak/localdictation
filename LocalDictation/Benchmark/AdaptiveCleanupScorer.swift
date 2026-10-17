#if DEBUG
import Foundation

enum AdaptiveCleanupScorer {
    static func score(
        sample: AdaptiveCleanupSample,
        cleanup: CleanupResult,
        duration: TimeInterval = 0
    ) -> AdaptiveCleanupSampleResult {
        let raw = Array(sample.raw)
        let ideal = Array(sample.ideal)
        let output = Array(cleanup.cleaned)
        let expected = changedSourcePositions(from: raw, to: ideal)
        let actual = Set(cleanup.edits.flatMap { $0.rawRange })
        let truePositive = expected.intersection(actual).count

        return AdaptiveCleanupSampleResult(
            identifier: sample.identifier,
            language: sample.language,
            raw: sample.raw,
            ideal: sample.ideal,
            output: cleanup.cleaned,
            editPrecision: actual.isEmpty ? (expected.isEmpty ? 1 : 0) : Double(truePositive) / Double(actual.count),
            editRecall: expected.isEmpty ? 1 : Double(truePositive) / Double(expected.count),
            protectedValuesPreserved: sample.protectedValues.allSatisfy(cleanup.cleaned.contains),
            punctuationF1: f1(expected: punctuation(in: ideal), actual: punctuation(in: output)),
            lineBreakF1: f1(expected: lineBreaks(in: ideal), actual: lineBreaks(in: output)),
            correctionEffort: editDistance(ideal, output),
            processingDuration: duration,
            unexpectedEditKinds: cleanup.edits.map(\.kind.rawValue).filter { !sample.allowedEditKinds.contains($0) }
        )
    }

    private static func changedSourcePositions(from source: [Character], to target: [Character]) -> Set<Int> {
        // The edit-distance alignment is deterministic and sufficient for a
        // benchmark score. Production provenance never uses this path.
        let rows = source.count + 1
        let columns = target.count + 1
        var table = Array(repeating: Array(repeating: 0, count: columns), count: rows)
        for i in 0..<rows { table[i][0] = i }
        for j in 0..<columns { table[0][j] = j }
        if source.isEmpty { return [] }
        if target.isEmpty { return Set(source.indices) }
        for i in 1..<rows {
            for j in 1..<columns {
                let cost = source[i - 1] == target[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
            }
        }
        var changed: Set<Int> = []
        var i = source.count
        var j = target.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, source[i - 1] == target[j - 1], table[i][j] == table[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, table[i][j] == table[i - 1][j - 1] + 1 {
                changed.insert(i - 1); i -= 1; j -= 1
            } else if i > 0, table[i][j] == table[i - 1][j] + 1 {
                changed.insert(i - 1); i -= 1
            } else {
                j -= 1
            }
        }
        return changed
    }

    private static func punctuation(in text: [Character]) -> [Character] {
        text.filter { $0.isPunctuation && $0 != "'" && $0 != "-" }
    }

    private static func lineBreaks(in text: [Character]) -> [Character] {
        text.filter(\.isNewline)
    }

    private static func editDistance(_ source: [Character], _ target: [Character]) -> Int {
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }
        var previous = Array(0...target.count)
        for i in 1...source.count {
            var current = Array(repeating: 0, count: target.count + 1)
            current[0] = i
            for j in 1...target.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[target.count]
    }

    private static func f1<T: Hashable>(expected: [T], actual: [T]) -> Double {
        let expectedCounts = counts(expected)
        let actualCounts = counts(actual)
        let truePositive = expectedCounts.reduce(0) { sum, pair in
            sum + min(pair.value, actualCounts[pair.key, default: 0])
        }
        if expected.isEmpty, actual.isEmpty { return 1 }
        guard truePositive > 0 else { return 0 }
        let precision = Double(truePositive) / Double(actual.count)
        let recall = Double(truePositive) / Double(expected.count)
        return 2 * precision * recall / (precision + recall)
    }

    private static func counts<T: Hashable>(_ values: [T]) -> [T: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
#endif
