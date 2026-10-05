import Foundation

@main
struct UsageAnalyticsTests {
    static var assertions = 0
    static let iso = ISO8601DateFormatter()
    static func date(_ value: String) -> Date { iso.date(from: value)! }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }
    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        expect(abs(actual - expected) < 1e-10 * max(1, abs(expected)), message)
    }
    static func event(_ at: Date, model: String = "gpt-4.1", input: Double = 100,
                      cached: Double = 0, output: Double = 10, path: String? = nil) -> LocalUsageEvent {
        LocalUsageEvent(timestamp: at, model: model, inputTokens: input, cachedInputTokens: cached,
                        outputTokens: output, repositoryPath: path)
    }
    static func history(_ events: [LocalUsageEvent], now: Date, start: Date = .distantPast) -> LocalUsageHistory {
        LocalUsageHistory(events: events, quotaSamples: [], scannedAt: now, lookbackStart: start, warning: nil)
    }

    static func main() {
        let originalZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = originalZone }
        testRangesRepositoriesAndCost()
        testEmptyAndInvalidMetadata()
        testUnpricedAndStableOrdering()
        testRepositoryCostOrder()
        print("PASS: \(assertions) analytics assertions covering local date ranges, DST, token accounting, repository identities, and unpriced usage")
    }

    static func testRangesRepositoriesAndCost() {
        let now = date("2026-11-03T18:00:00Z")
        let weekStart = date("2026-10-28T07:00:00Z")
        let events = [
            event(weekStart, input: 300_000, cached: 200_000, output: 10_000, path: "/projects/one/shared"),
            event(now, model: "gpt-6-luna", input: 200_000, cached: 100_000, output: 1_000,
                  path: "/projects/one/shared/./"),
            event(now, model: "fixture-unpriced", input: 40, cached: 10, output: 10, path: "/projects/two/shared"),
            event(now, model: "fixture-unpriced", input: 60, output: 20),
            event(weekStart.addingTimeInterval(-1), input: 900, output: 99),
            event(date("2026-10-15T12:00:00Z")),
            event(date("2026-09-04T12:00:00Z"), input: 500, output: 5),
            event(now.addingTimeInterval(1), input: 9_999_999)
        ]
        let source = history(events, now: now)
        let week = UsageAnalytics.summarize(source, range: .week, now: now)
        expect(week.startDate == weekStart, "A week starts at local midnight six calendar days ago")
        expect(week.endDate == now, "End boundary remains the requested snapshot time")
        near(week.totalTokens, 511_130, "Tokens are inclusive input plus output, not input plus cache plus output")
        near(week.inputTokens, 500_100, "Input includes cached input")
        near(week.cachedInputTokens, 300_010, "Cached input is retained independently as a subset")
        near(week.outputTokens, 11_030, "Output is counted once")
        near(week.pricedTokens, 511_000, "Verified-model tokens are retained as the priced coverage")
        near(week.unpricedTokens, 130, "Unknown model usage remains in every total")
        near(week.estimatedCostUSD, 0.3915, "Per-event API estimates subtract cached input before applying ordinary input rates")
        near(week.pricedTokens + week.unpricedTokens, week.totalTokens, "Pricing coverage partitions the token total")
        expect(week.models.map(\.model) == ["gpt-4.1", "gpt-6-luna", "fixture-unpriced"], "Models sort by descending tokens")
        near(week.models.reduce(0) { $0 + $1.tokens }, week.totalTokens, "Model totals reconcile with the global total")
        expect(week.repositories.count == 3, "Path normalization merges aliases while unknown usage keeps its own row")
        expect(week.repositories.filter { $0.name == "shared" }.count == 2, "Equal repository names never merge separate roots")
        let one = week.repositories.first { $0.id == "/projects/one/shared" }!
        near(one.tokens, 511_000, "Both models aggregate under the exact repository path")
        near(one.costUSD, 0.3915, "Repository cost uses the same per-event estimates as the total")
        expect(one.path == "/projects/one/shared", "The full path remains available for disambiguation")
        let two = week.repositories.first { $0.path == "/projects/two/shared" }!
        near(two.tokens, 50, "Unknown-price usage remains visible in a known repository")
        expect(two.costUSD == 0 && two.pricedTokens == 0 && two.unpricedTokens == 50,
               "Unpriced repository rows expose missing coverage instead of implying free usage")
        let unknown = week.repositories.first { $0.id == "unknown" }!
        expect(unknown.name == "Unknown repository" && unknown.path == nil && unknown.tokens == 80,
               "Unattributed usage has an explicit, stable repository row")
        near(week.repositories.reduce(0) { $0 + $1.tokens }, week.totalTokens, "Repository totals reconcile")
        near(week.repositories.reduce(0) { $0 + $1.costUSD }, week.estimatedCostUSD, "Repository costs reconcile")
        expect(week.days.count == 7, "A seven-day chart includes zero-use calendar days")
        expect(week.days.filter { $0.tokens == 0 }.count == 5, "Idle days stay visible")
        near(week.days.reduce(0) { $0 + $1.tokens }, week.totalTokens, "Daily totals reconcile")
        let intervals = zip(week.days.dropFirst(), week.days).map { $0.date.timeIntervalSince($1.date) }
        expect(intervals.contains(25 * 3600), "Calendar stepping preserves the 25-hour fall-back day")

        let month = UsageAnalytics.summarize(source, range: .month, now: now)
        expect(month.startDate == date("2026-10-05T07:00:00Z") && month.days.count == 30,
               "Month means thirty local calendar days including today")
        near(month.totalTokens, 512_239, "Month includes older events but excludes ancient and future events")
        let all = UsageAnalytics.summarize(source, range: .all, now: now)
        expect(all.startDate == date("2026-09-04T07:00:00Z"), "All available begins at the first valid recorded activity")
        expect(all.days.count == 61, "All-history chart is bounded by observed activity")
        near(all.totalTokens, 512_744, "All includes every available past event without including the future")
        expect(UsageReportingRange.all.title == "All available", "All does not claim complete account lifetime coverage")
    }

    static func testEmptyAndInvalidMetadata() {
        let now = date("2026-11-03T18:00:00Z")
        let invalid = [
            event(.distantPast, input: -100),
            event(now, input: .nan), event(now, input: .infinity),
            event(now, input: 1e308), event(now, input: 0.5), event(now, cached: 0.5),
            event(now, input: 100, cached: 101), event(now, output: -1),
            event(now, input: 0, cached: 0, output: 0),
            event(Date(timeIntervalSince1970: .nan))
        ]
        let summary = UsageAnalytics.summarize(history(invalid, now: now), range: .all, now: now)
        expect(summary.totalTokens == 0 && summary.estimatedCostUSD == 0, "Invalid metadata never poisons a summary")
        expect(summary.models.isEmpty && summary.repositories.isEmpty, "Invalid or zero events do not create phantom rows")
        expect(summary.days.count == 1 && summary.days[0].tokens == 0, "Empty all-history results contain today only")
        expect(summary.startDate == date("2026-11-03T08:00:00Z"), "Missing history never invents a1970 epoch or distantPast chart")
        let week = UsageAnalytics.summarize(history([], now: now), range: .week, now: now)
        expect(week.days.count == 7 && week.totalTokens == 0, "Empty fixed-range charts retain the selected calendar range")
    }

    static func testUnpricedAndStableOrdering() {
        let now = date("2026-11-03T18:00:00Z")
        let source = history([
            event(now, model: "unknown-z", path: "/b/same"),
            event(now, model: "unknown-a", path: "/a/same"),
            event(now, model: "unknown-m", path: "relative-path")
        ], now: now)
        let value = UsageAnalytics.summarize(source, range: .all, now: now)
        expect(value.totalTokens == 330 && value.unpricedTokens == 330 && value.pricedTokens == 0,
               "A wholly unpriced history keeps its numerical totals")
        expect(value.estimatedCostUSD == 0, "Unknown prices do not inherit a price from a similar name")
        expect(value.models.map(\.model) == ["unknown-a", "unknown-m", "unknown-z"], "Equal model totals use deterministic lexical order")
        expect(value.repositories.map(\.id) == ["/a/same", "/b/same", "unknown"], "Equal repository totals use full-path order")
    }

    static func testRepositoryCostOrder() {
        let now = date("2026-11-03T18:00:00Z")
        let source = history([
            event(now, model: "gpt-6-astra", input: 0, output: 100_000, path: "/expensive"),
            event(now, model: "gpt-6-luna", input: 1_000_000, output: 0, path: "/many-tokens"),
            event(now, model: "unknown", input: 9_000_000, output: 0, path: "/unpriced")
        ], now: now)
        let value = UsageAnalytics.summarize(source, range: .all, now: now)
        expect(value.repositories.map(\.id) == ["/expensive", "/many-tokens", "/unpriced"],
               "Repository display is ordered by estimated cost, with wholly unpriced repositories last")
    }
}
