import Foundation

@main
struct ModelUsageRatesTests {
    static let now = Date(timeIntervalSince1970: 1_790_496_000)
    static var assertions = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError(message) }
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        expect(abs(actual - expected) <= 0.000001 * max(1, abs(expected)), message)
    }

    static func event(_ model: String = "model-a", at timestamp: Date = now,
                      input: Double = 80, cached: Double = 60, output: Double = 20) -> LocalUsageEvent {
        LocalUsageEvent(timestamp: timestamp, model: model, inputTokens: input,
                        cachedInputTokens: cached, outputTokens: output)
    }

    static func history(_ events: [LocalUsageEvent], hours: Double = 168,
                        warning: String? = nil, scannedAt: Date = now) -> LocalUsageHistory {
        LocalUsageHistory(events: events, quotaSamples: [], scannedAt: scannedAt,
                          lookbackStart: scannedAt.addingTimeInterval(-hours * 3600), warning: warning)
    }

    static func testTokenAccounting() {
        let rows = ModelUsageRates.calculate(history: history([
            event(input: 800, cached: 600, output: 200),
            event(input: 100, cached: 100, output: 50)
        ], hours: 2))
        expect(rows.count == 1, "Events from one model aggregate")
        let rate = rows[0]
        near(rate.inputTokens, 900, "Input includes cached input")
        near(rate.cachedInputTokens, 700, "Cached subset remains available separately")
        near(rate.outputTokens, 250, "Output accumulates independently")
        near(rate.totalTokens, 1150, "Cached input is not double-counted in total")
        near(rate.tokensPerHour, 575, "Hourly throughput uses recorded tokens")
        near(rate.tokensPerDay, 13_800, "Daily rate is the same elapsed-time average")
    }

    static func testMixedModelsAndIdleTime() {
        // Every model uses the full reporting interval, not the elapsed time
        // between its first and last event. Sparse/idle use does not inflate rates.
        let rows = ModelUsageRates.calculate(history: history([
            event("model-a", input: 1344, cached: 1000, output: 336),
            event("model-b", at: now.addingTimeInterval(-60), input: 2520, cached: 2000, output: 840)
        ]))
        expect(rows.map(\.model) == ["model-b", "model-a"], "Mixed models remain independent and sort by total")
        near(rows[0].elapsedHours, 168, "Seven days includes all idle time")
        near(rows[0].tokensPerHour, 20, "Single recent model event does not produce a one-minute rate")
        near(rows[1].tokensPerHour, 10, "Each model has its own numerator and common denominator")
        near(rows[1].tokensPerDay, 240, "Seven-day average normalizes to a daily pace")

        let partial = ModelUsageRates.calculate(history: history([event()], hours: 1, warning: "Partial history"))
        expect(partial.count == 1, "Recorded rates remain available despite attribution warning or absent quota samples")
        near(partial[0].tokensPerHour, 100, "Partial-history known tokens retain their recorded rate")
        let unknown = ModelUsageRates.calculate(history: history([event("unknown")], hours: 1))
        expect(unknown.first?.model == "unknown", "Known token amounts with unknown model identity remain visible")
    }

    static func testReportingBoundaries() {
        let start = now.addingTimeInterval(-2 * 3600)
        let rows = ModelUsageRates.calculate(history: history([
            event(at: start), event(at: now),
            event(at: start.addingTimeInterval(-1)), event(at: now.addingTimeInterval(1))
        ], hours: 2))
        near(rows[0].totalTokens, 200, "Start/end inclusive; older and future events excluded")
        near(rows[0].elapsedHours, 2, "Narrower known history controls the denominator")
        near(rows[0].tokensPerHour, 100, "A narrow interval is not padded to a week")

        let bounded = ModelUsageRates.calculate(history: history([
            event(at: now.addingTimeInterval(-8 * 86400)), event()
        ], hours: 14 * 24))
        near(bounded[0].elapsedHours, 168, "Longer histories are bounded to seven elapsed days")
        near(bounded[0].totalTokens, 100, "Seven-day cap excludes older tokens")
        expect(ModelUsageRates.calculate(history: history([], hours: 168)).isEmpty, "Empty history invents no model rows")

        let ties = ModelUsageRates.calculate(history: history([event("z-model"), event("a-model")]))
        expect(ties.map(\.model) == ["a-model", "z-model"], "Equal totals have stable model ordering")
    }

    static func testInvalidData() {
        let invalid = [
            event("empty", input: 0, cached: 0, output: 0),
            event("negative-input", input: -1, cached: 0),
            event("negative-cache", cached: -1),
            event("negative-output", output: -1),
            event("impossible-cache", input: 10, cached: 11),
            event("nan-input", input: .nan),
            event("infinite-cache", cached: .infinity),
            event("infinite-output", output: .infinity),
            event("overflow-event", input: .greatestFiniteMagnitude, cached: 0, output: .greatestFiniteMagnitude),
            event("bad-date", at: Date(timeIntervalSince1970: .nan)),
            event("  ")
        ]
        let rates = ModelUsageRates.calculate(history: history(invalid + [event()], hours: 1))
        expect(rates.count == 1 && rates[0].model == "model-a", "Invalid events do not contaminate valid models")
        near(rates[0].totalTokens, 100, "Valid event survives invalid neighbors")
        expect(ModelUsageRates.calculate(history: history([event()], hours: 0)).isEmpty, "Zero elapsed interval is invalid")
        expect(ModelUsageRates.calculate(history: history([event()], hours: -1)).isEmpty, "Inverted reporting interval is invalid")
        let badStart = LocalUsageHistory(events: [event()], quotaSamples: [], scannedAt: now,
                                         lookbackStart: Date(timeIntervalSince1970: .infinity), warning: nil)
        expect(ModelUsageRates.calculate(history: badStart).isEmpty, "Nonfinite reporting start is invalid")
        let badEnd = LocalUsageHistory(events: [event()], quotaSamples: [], scannedAt: Date(timeIntervalSince1970: .nan),
                                       lookbackStart: now, warning: nil)
        expect(ModelUsageRates.calculate(history: badEnd).isEmpty, "Nonfinite scan date is invalid")
        let overflow = ModelUsageRates.calculate(history: history([
            event("overflow", input: .greatestFiniteMagnitude / 2, cached: 0, output: 0),
            event("overflow", input: .greatestFiniteMagnitude / 2, cached: 0, output: 0),
            event("overflow", input: .greatestFiniteMagnitude / 2, cached: 0, output: 0), event()
        ], hours: 1))
        expect(overflow.count == 1 && overflow[0].model == "model-a", "Accumulation overflow cannot emit infinite rates")
        let overflowRate = ModelUsageRates.calculate(history: history([
            event("rate-overflow", input: .greatestFiniteMagnitude / 2, cached: 0, output: 0)
        ], hours: 1))
        expect(overflowRate.isEmpty, "Daily rate overflow is rejected even when totals are finite")
    }

    static func main() {
        testTokenAccounting()
        testMixedModelsAndIdleTime()
        testReportingBoundaries()
        testInvalidData()
        print("PASS: \(assertions) recorded-rate assertions covering token mix, mixed models, idle time, reporting boundaries, and invalid data")
    }
}
