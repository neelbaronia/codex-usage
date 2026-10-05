import Foundation

/// A bundled Standard, short-context API list-price snapshot, not a bill.
/// Missing cache-write and per-request context data can understate API cost.
enum ModelPricing {
    static let sourceURL = "https://developers.openai.com/api/docs/pricing"
    static let checkedAt = "2026-10-05"
    static let basis = "Standard short-context API list prices"

    private struct Rates {
        let input: Double
        let cached: Double
        let output: Double
    }

    // USD per one million tokens. Exact published model IDs only: no prefix,
    // date-suffix, case, or friendly-name inference. See docs/PRICING.md.
    private static let rates: [String: Rates] = [
        "gpt-6-astra": Rates(input: 10, cached: 1, output: 50),
        "gpt-6.1-sol": Rates(input: 2, cached: 0.1, output: 10),
        "gpt-6-sol": Rates(input: 2, cached: 0.2, output: 10),
        "gpt-6-luna": Rates(input: 0.1, cached: 0.01, output: 0.5),
        "gpt-5.6-sol": Rates(input: 4, cached: 0.4, output: 20),
        "gpt-5.6-terra": Rates(input: 2, cached: 0.2, output: 12),
        "gpt-5.6-luna": Rates(input: 0.2, cached: 0.02, output: 1.2),
        "gpt-5.5": Rates(input: 5, cached: 0.5, output: 30),
        "gpt-5.4": Rates(input: 2.5, cached: 0.25, output: 15),
        "gpt-5.4-mini": Rates(input: 0.75, cached: 0.075, output: 4.5),
        "gpt-5.4-nano": Rates(input: 0.2, cached: 0.02, output: 1.25),
        "gpt-5.3-codex": Rates(input: 1.75, cached: 0.175, output: 14),
        "gpt-5.2-codex": Rates(input: 1.75, cached: 0.175, output: 14),
        "gpt-5.1-codex": Rates(input: 1.25, cached: 0.125, output: 10),
        "gpt-5.1-codex-max": Rates(input: 1.25, cached: 0.125, output: 10),
        "gpt-5.2": Rates(input: 1.75, cached: 0.175, output: 14),
        "gpt-5.1": Rates(input: 1.25, cached: 0.125, output: 10),
        "gpt-5": Rates(input: 1.25, cached: 0.125, output: 10),
        "gpt-5-mini": Rates(input: 0.25, cached: 0.025, output: 2),
        "gpt-5-nano": Rates(input: 0.05, cached: 0.005, output: 0.4),
        "gpt-4.1": Rates(input: 2, cached: 0.5, output: 8),
        "gpt-4.1-mini": Rates(input: 0.4, cached: 0.1, output: 1.6),
        "gpt-4.1-nano": Rates(input: 0.1, cached: 0.025, output: 0.4)
    ]

    /// `inputTokens` includes `cachedInputTokens`; `outputTokens` already includes
    /// reasoning. Counts may cover many requests, so their sum must never select
    /// a per-request long-context tier. Unknown models or invalid counts are nil.
    static func estimateUSD(model: String, inputTokens: Double,
                            cachedInputTokens: Double, outputTokens: Double) -> Double? {
        guard let price = rates[model],
              validCount(inputTokens), validCount(cachedInputTokens), validCount(outputTokens),
              cachedInputTokens <= inputTokens else { return nil }
        let cost = ((inputTokens - cachedInputTokens) * price.input
                    + cachedInputTokens * price.cached
                    + outputTokens * price.output) / 1_000_000
        return cost.isFinite ? cost : nil
    }

    private static func validCount(_ count: Double) -> Bool {
        // Above 2^53 - 1, a Double cannot safely represent every integer token.
        count.isFinite && count >= 0 && count <= 9_007_199_254_740_991
            && count.rounded(.towardZero) == count
    }
}
