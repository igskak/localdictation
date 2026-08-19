import Foundation

/// Numbers, amounts, and dates.
///
/// The first signal, and the one carrying most of the product promise: an
/// amount or a date that comes out wrong reads exactly as fluently as one that
/// came out right, and nobody remembers which digits they spoke.
struct NumberRiskSignal: RiskSignal {
    let identifier = "numbers"

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        context.words.compactMap { word in
            guard let category = CriticalTokens.category(of: word.text) else { return nil }
            let reason: RiskReason = switch category {
            case .number: .number
            case .currency: .currency
            case .date: .date
            }
            return RawRiskSpan(reason: reason, range: word.range)
        }
    }
}
