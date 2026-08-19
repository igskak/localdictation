import Foundation

/// Numbers, amounts, and dates.
///
/// The first signal, and the one carrying most of the product promise: an
/// amount or a date that comes out wrong reads exactly as fluently as one that
/// came out right, and nobody remembers which digits they spoke.
struct NumberRiskSignal: RiskSignal {
    let identifier = "numbers"

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        let words = context.words
        let window = CriticalTokens.dateContextWindow
        return words.enumerated().compactMap { index, word in
            // An ordinal is a day of the month or an ordinary adjective
            // depending on what stands next to it, so the neighbours travel
            // with the word.
            let previous = words[max(index - window, 0)..<index].map(\.text)
            let next = words[(index + 1)..<min(index + 1 + window, words.count)].map(\.text)
            guard let category = CriticalTokens.category(of: word.text, precededBy: previous, followedBy: next) else { return nil }
            let reason: RiskReason = switch category {
            case .number: .number
            case .currency: .currency
            case .date: .date
            }
            return RawRiskSpan(reason: reason, range: word.range)
        }
    }
}
