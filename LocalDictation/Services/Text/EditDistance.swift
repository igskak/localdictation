import Foundation

/// Levenshtein distance over `Character`s, with an early exit.
///
/// Used by the glossary signal to tell "the engine wrote a near-miss of a term
/// the user cares about" from "the engine wrote an unrelated word". The bound
/// matters: without it, every token would be compared in full against every
/// glossary entry for a verdict that is discarded anyway.
enum EditDistance {
    /// Returns the distance, or `nil` when it provably exceeds `limit`.
    static func distance(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let left = Array(lhs)
        let right = Array(rhs)

        if abs(left.count - right.count) > limit { return nil }
        if left.isEmpty { return right.count <= limit ? right.count : nil }
        if right.isEmpty { return left.count <= limit ? left.count : nil }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowMinimum = current[0]

            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                rowMinimum = min(rowMinimum, current[j])
            }

            if rowMinimum > limit { return nil }
            swap(&previous, &current)
        }

        let result = previous[right.count]
        return result <= limit ? result : nil
    }
}
