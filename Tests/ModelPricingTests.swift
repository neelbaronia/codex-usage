import Foundation

@main
struct ModelPricingTests {
    static var assertions = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError(message) }
    }

    static func near(_ actual: Double?, _ expected: Double, _ message: String) {
        expect(actual.map { abs($0 - expected) <= 1e-12 * max(1, abs(expected)) } ?? false, message)
    }

    static func estimate(_ model: String = "gpt-6-astra", input: Double = 300_000,
                         cached: Double = 200_000, output: Double = 10_000) -> Double? {
        ModelPricing.estimateUSD(model: model, inputTokens: input,
                                 cachedInputTokens: cached, outputTokens: output)
    }

    static func testInclusiveInputAndPrecision() {
        near(estimate(), 1.7, "100K uncached + 200K cached + 10K output: cached input is charged once")
        near(estimate(input: 1_000_000, cached: 1_000_000, output: 0), 1,
             "Entirely cached input uses only the cached rate")
        near(estimate(input: 1_000_000, cached: 0, output: 0), 10,
             "Uncached input uses the ordinary rate")
        near(estimate(input: 0, cached: 0, output: 1_000_000), 50,
             "Output is priced independently and includes reasoning already")
        near(estimate(input: 0, cached: 0, output: 0), 0, "Known zero usage is a priced zero")
        near(estimate("gpt-5-nano", input: 1, cached: 1, output: 0), 0.000000005,
             "Small cached charges are not rounded to cents before aggregation")
        near(estimate(input: 30_000_000, cached: 20_000_000, output: 1_000_000), 170,
             "Aggregate totals above 272K never imply a single long-context request")
        near(estimate(input: 9_007_199_254_740_991, cached: 0, output: 0), 90_071_992_547.40991,
             "Large exactly representable counts remain finite")
    }

    static func testPublishedSnapshot() {
        // Independent price fixtures from the official table checked 2026-10-05.
        // One million uncached + one million cached + one million output tokens.
        let publishedTotals: [(String, Double)] = [
            ("gpt-6-astra", 61), ("gpt-6.1-sol", 12.1),
            ("gpt-6-sol", 12.2), ("gpt-6-luna", 0.61),
            ("gpt-5.6-sol", 24.4), ("gpt-5.6-terra", 14.2),
            ("gpt-5.6-luna", 1.42), ("gpt-5.5", 35.5),
            ("gpt-5.4", 17.75), ("gpt-5.4-mini", 5.325),
            ("gpt-5.4-nano", 1.47), ("gpt-5.3-codex", 15.925),
            ("gpt-5.2-codex", 15.925), ("gpt-5.1-codex", 11.375),
            ("gpt-5.1-codex-max", 11.375), ("gpt-5.2", 15.925),
            ("gpt-5.1", 11.375), ("gpt-5", 11.375),
            ("gpt-5-mini", 2.275), ("gpt-5-nano", 0.455),
            ("gpt-4.1", 10.5), ("gpt-4.1-mini", 2.1), ("gpt-4.1-nano", 0.525)
        ]
        for (model, expected) in publishedTotals {
            near(estimate(model, input: 2_000_000, cached: 1_000_000, output: 1_000_000), expected,
                 "Published short-context Standard snapshot for \(model)")
        }
        expect(ModelPricing.checkedAt == "2026-10-05", "The bundled snapshot discloses its verification date")
        expect(ModelPricing.sourceURL == "https://developers.openai.com/api/docs/pricing",
               "Price provenance links to the official source")
    }

    static func testExactIdentifiers() {
        for unknown in ["", "unknown", "codex-auto-review", "astra", "GPT-6-Astra",
                        "gpt-6", "gpt-6-astra ", " gpt-6-astra", "gpt-6-astra-2026-08-25",
                        "gpt-6-sol-fast", "gpt-6-sol-unverified", "gpt-5.4-pro", "gpt-5-codex"] {
            expect(estimate(unknown) == nil, "Unverified IDs never inherit a similar model's price: \(unknown)")
            expect(estimate(unknown, input: 0, cached: 0, output: 0) == nil,
                   "Unknown models stay unpriced even with zero usage: \(unknown)")
        }
    }

    static func testInvalidCounts() {
        for invalid in [-1.0, Double.nan, Double.infinity, -Double.infinity,
                        0.5, 9_007_199_254_740_992, Double.greatestFiniteMagnitude] {
            expect(estimate(input: invalid, cached: 0) == nil, "Invalid input is rejected")
            expect(estimate(cached: invalid) == nil, "Invalid cached input is rejected")
            expect(estimate(output: invalid) == nil, "Invalid output is rejected")
        }
        expect(estimate(input: 1, cached: 2, output: 0) == nil, "Cached input cannot exceed inclusive input")
        expect(estimate(input: 0, cached: 1, output: 0) == nil, "Cached tokens cannot exist without input")
    }

    static func main() {
        testInclusiveInputAndPrecision()
        testPublishedSnapshot()
        testExactIdentifiers()
        testInvalidCounts()
        print("PASS: \(assertions) pricing assertions covering cached input, published rates, exact IDs, and invalid counters")
    }
}
