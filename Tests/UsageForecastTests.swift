import Foundation

@main
struct UsageForecastTests {
    static let now = Date(timeIntervalSince1970: 1_790_496_000)
    static let duration = 10_080
    static let reset = now.timeIntervalSince1970 + 12 * 3600
    static var assertions = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError(message) }
    }

    static func near(_ value: Double?, _ expected: Double, _ message: String) {
        expect(value.map { abs($0 - expected) <= 0.000001 * max(1, abs(expected)) } ?? false, message)
    }

    static func sample(_ timestamp: Date, _ used: Double, resetAt: TimeInterval = reset,
                       id: String = "codex", plan: String? = "pro", minutes: Int = duration) -> LocalQuotaSample {
        LocalQuotaSample(timestamp: timestamp, limitID: id, windowMinutes: minutes,
                         resetsAt: resetAt, usedPercent: used, planType: plan)
    }

    static func event(_ timestamp: Date, model: String = "model-a", tokens: Double = 100) -> LocalUsageEvent {
        LocalUsageEvent(timestamp: timestamp, model: model, inputTokens: tokens * 0.8,
                        cachedInputTokens: tokens * 0.6, outputTokens: tokens * 0.2)
    }

    static func history(events: [LocalUsageEvent], samples: [LocalQuotaSample], scannedAt: Date = now,
                        warning: String? = nil) -> LocalUsageHistory {
        LocalUsageHistory(events: events, quotaSamples: samples, scannedAt: scannedAt,
                          lookbackStart: now.addingTimeInterval(-7 * 86400), warning: warning)
    }

    static func snapshot(used: Double = 16, resetAt: TimeInterval = reset,
                         fetchedAt: Date = now, allowed: Bool? = true) -> (UsageSnapshot, UsageWindow) {
        let window = UsageWindow(usedPercent: used, windowDurationMins: duration, resetsAt: resetAt)
        return (UsageSnapshot(fetchedAt: fetchedAt,
                              buckets: [UsageBucket(id: "codex", name: nil, planType: "pro", primary: window, secondary: nil)],
                              availableResets: nil, ordinaryUsageAllowed: allowed), window)
    }

    static func forecast(_ history: LocalUsageHistory, used: Double = 16,
                         resetAt: TimeInterval = reset, fetchedAt: Date = now,
                         allowed: Bool? = true) -> UsageForecast? {
        let (snapshot, window) = snapshot(used: used, resetAt: resetAt, fetchedAt: fetchedAt, allowed: allowed)
        return UsageForecaster.forecast(history: history, snapshot: snapshot, window: window,
                                        planType: "pro", now: now)
    }

    // Three token events inside each disjoint 30-minute block, away from the
    // one-minute contamination guards. The account meter advances by two points.
    static func fixture(models: [String] = ["model-a", "model-a", "model-a"],
                        tokenAmounts: [Double]? = nil) -> LocalUsageHistory {
        let start = now.addingTimeInterval(-Double(models.count) * 1800)
        var samples = [sample(start, 10)]
        var events: [LocalUsageEvent] = []
        for (index, model) in models.enumerated() {
            let blockStart = start.addingTimeInterval(Double(index) * 1800)
            for offset in [300.0, 600, 1200] {
                events.append(event(blockStart.addingTimeInterval(offset), model: model,
                                    tokens: tokenAmounts?[index] ?? 100))
            }
            samples.append(sample(blockStart.addingTimeInterval(1800), 12 + Double(index) * 2))
        }
        return history(events: events, samples: samples)
    }

    static func testCleanCalibration() {
        let result = forecast(fixture())!
        let model = result.models.first!
        expect(model.sampleCount == 3, "Three disjoint clean blocks qualify")
        near(model.sampledHours, 1.5, "Sampled elapsed time retained")
        near(model.recentTokens, 900, "Cached input is not added twice")
        near(model.hours, 21, "84 remaining / 4 observed points per hour")
        near(model.lowerHours, 14, "Fast bound includes percentage quantization")
        near(model.upperHours, 42, "Slow bound includes percentage quantization")
        near(model.remainingTokens, 12_600, "Token estimate uses observed model burn")
        near(result.overallHours, 21, "Overall meter pace matches the clean sample")
        near(result.overallSampleHours, 1.5, "Overall sample horizon is disclosed")
        near(result.hoursUntilReset, 12, "Reset comparison uses the live reset")
        expect(result.overallHours! > result.hoursUntilReset, "Pace projects past reset; UI can say lasts until reset")

        let zero = forecast(fixture(), used: 100)!
        near(zero.models.first?.hours, 0, "No remaining quota projects zero hours")
        near(zero.models.first?.remainingTokens, 0, "No remaining quota projects zero tokens")
    }

    static func testDifferentModels() {
        let data = fixture(models: Array(repeating: "model-a", count: 3) + Array(repeating: "model-b", count: 3),
                           tokenAmounts: [100, 100, 100, 400, 400, 400])
        let rows = forecast(data, used: 22)!.models
        let a = rows.first { $0.model == "model-a" }!
        let b = rows.first { $0.model == "model-b" }!
        expect(a.sampleCount == 3 && b.sampleCount == 3, "Models calibrate independently")
        near(a.remainingTokens, 11_700, "Model A's empirical token capacity")
        near(b.remainingTokens, 46_800, "Model B does not inherit Model A's token weight")
        near(a.hours, b.hours!, "Equal sampled elapsed pace may coexist with different token burn")
    }

    static func testMixedAndUnknown() {
        let clean = fixture()
        let mixed = history(events: clean.events + clean.quotaSamples.dropLast().map {
            event($0.timestamp.addingTimeInterval(900), model: "model-b", tokens: 1)
        }, samples: clean.quotaSamples)
        expect(forecast(mixed)!.models.allSatisfy { $0.hours == nil && $0.sampleCount == 0 },
               "Even one other-model token rejects a mixed quota interval")
        near(forecast(mixed)!.overallHours, 21, "Mixed activity still supports account-wide pace")

        let boundary = history(events: clean.events + [event(clean.quotaSamples[1].timestamp.addingTimeInterval(30), model: "model-b")],
                               samples: clean.quotaSamples)
        let model = forecast(boundary)!.models.first { $0.model == "model-a" }!
        expect(model.sampleCount == 1 && model.hours == nil, "Boundary guard rejects both neighboring mixed blocks")
        let unknown = forecast(fixture(models: Array(repeating: "unknown", count: 3)))!.models.first!
        expect(unknown.sampleCount == 0 && unknown.remainingTokens == nil, "Unknown model never acquires a forecast")
    }

    static func testZeroChangeAndGaps() {
        let start = now.addingTimeInterval(-3 * 3600)
        var samples = [sample(start, 10)]
        var events: [LocalUsageEvent] = []
        for index in 0..<3 {
            let base = start.addingTimeInterval(Double(index) * 3600)
            samples.append(sample(base.addingTimeInterval(1800), 10 + Double(index) * 2))
            samples.append(sample(base.addingTimeInterval(3600), 12 + Double(index) * 2))
            for offset in [2100.0, 2400, 3000] { events.append(event(base.addingTimeInterval(offset))) }
        }
        let row = forecast(history(events: events, samples: samples))!.models.first!
        expect(row.sampleCount == 3, "Zero-change samples remain within qualifying blocks")
        near(row.sampledHours, 3, "Idle elapsed periods are included")
        near(row.hours, 42, "Discarding idle samples would incorrectly halve this runway")

        let sparse = forecast(fixture(models: ["model-a", "model-a"]), used: 14)!.models.first!
        expect(sparse.sampleCount == 2 && sparse.hours == nil, "Two clean blocks do not qualify")
        let gap = history(events: events, samples: [sample(now.addingTimeInterval(-4 * 3600), 10), sample(now, 16)])
        expect(forecast(gap)!.models.allSatisfy { $0.sampleCount == 0 && $0.hours == nil },
               "A long gap cannot become a model-calibration block")
    }

    static func testResetDriftAndDrop() {
        let clean = fixture()
        let drifted = clean.quotaSamples.enumerated().map { index, row in
            sample(row.timestamp, row.usedPercent, resetAt: reset - 360 + Double(index) * 120)
        }
        expect(forecast(history(events: clean.events, samples: drifted))!.models.first!.sampleCount == 3,
               "Small reset timestamp drift does not split one quota window")

        let six = fixture(models: Array(repeating: "model-a", count: 6))
        let points: [Double] = [10, 12, 14, 16, 3, 5, 7]
        let dropped = six.quotaSamples.enumerated().map { sample($1.timestamp, points[$0]) }
        let row = forecast(history(events: six.events, samples: dropped), used: 7)!.models.first!
        expect(row.sampleCount == 5, "Meter drop splits calibration even when reset timestamp is unchanged")
        near(row.hours, 23.25, "Drop is never treated as negative or bridged consumption")

        let switched = six.quotaSamples.enumerated().map { index, row in
            sample(row.timestamp, row.usedPercent, resetAt: index < 4 ? now.timeIntervalSince1970 - 75 * 60 : reset)
        }
        expect(forecast(history(events: six.events, samples: switched), used: 22)!.models.first!.sampleCount == 5,
               "A different reset window cannot bridge a rising meter")
        let afterDrop = forecast(history(events: six.events, samples: dropped), used: 7)!
        near(afterDrop.overallSampleHours, 1, "Overall pace uses only the latest uninterrupted segment")
        near(afterDrop.overallHours, 23.25, "Overall pace excludes quota before a reset/drop")

        let expired = clean.quotaSamples.map {
            sample($0.timestamp, $0.usedPercent, resetAt: now.timeIntervalSince1970 - 2 * 3600)
        }
        expect(forecast(history(events: clean.events, samples: expired))!.models.first!.sampleCount == 0,
               "Quota measurements recorded after their reset are excluded from calibration")
    }

    static func testGuardsAndOrdering() {
        let clean = fixture()
        expect(forecast(clean, fetchedAt: now.addingTimeInterval(-601)) == nil, "Stale live quota cannot be extrapolated")
        expect(forecast(history(events: clean.events, samples: clean.quotaSamples, scannedAt: now.addingTimeInterval(-901))) == nil,
               "Stale local history cannot be extrapolated")
        expect(forecast(clean, fetchedAt: now.addingTimeInterval(1)) == nil, "Future live samples are invalid")
        expect(forecast(history(events: clean.events, samples: clean.quotaSamples, scannedAt: now.addingTimeInterval(1))) == nil,
               "Future scan timestamps are invalid")
        expect(forecast(clean, resetAt: now.timeIntervalSince1970) == nil, "Expired live window has no forecast")
        expect(forecast(clean, allowed: false) == nil, "Restricted account cannot promise runway")

        let (snapshot, _) = snapshot()
        let unknown = UsageWindow(usedPercent: nil, windowDurationMins: duration, resetsAt: reset)
        expect(UsageForecaster.forecast(history: clean, snapshot: snapshot, window: unknown, planType: "pro", now: now) == nil,
               "Unknown remaining percentage cannot be extrapolated")
        let reordered = history(events: clean.events.reversed(), samples: clean.quotaSamples.reversed() + clean.quotaSamples)
        near(forecast(reordered)!.models.first?.hours, 21, "Out-of-order and duplicate quota snapshots do not multiply blocks")
        for invalidSamples in [
            clean.quotaSamples.map { sample($0.timestamp, $0.usedPercent, id: "other") },
            clean.quotaSamples.map { sample($0.timestamp, $0.usedPercent, plan: "plus") },
            clean.quotaSamples.map { sample($0.timestamp, $0.usedPercent, minutes: 300) }
        ] {
            let result = forecast(history(events: clean.events, samples: invalidSamples))!
            expect(result.models.allSatisfy { $0.hours == nil } && result.overallHours == nil,
                   "Different bucket, plan, or duration must not contaminate calibration")
        }
        let noEvents = forecast(history(events: [], samples: clean.quotaSamples))!
        expect(noEvents.models.isEmpty, "No local activity cannot invent a model forecast")
        near(noEvents.overallHours, 21, "Observed account pace does not require local model attribution")
        let partial = forecast(history(events: clean.events, samples: clean.quotaSamples, warning: "Some model activity omitted"))!
        expect(partial.models.allSatisfy { $0.hours == nil && $0.remainingTokens == nil && $0.sampleCount == 0 },
               "Ambiguous history cannot produce a model-specific forecast")
        near(partial.models.first?.recentTokens, 900, "Partial history still retains known token totals")
        near(partial.overallHours, 21, "Partial history does not suppress account-wide meter pace")
    }

    static func liveSummary() throws {
        let history = try LocalUsageHistoryReader().read()
        let snapshot = try UsageProvider().fetch()
        guard let bucket = snapshot.buckets.first(where: { $0.id == "codex" }) ?? snapshot.buckets.first,
              let window = [bucket.primary, bucket.secondary].compactMap({ $0 }).filter({ $0.remainingPercent != nil })
                .min(by: { $0.remainingPercent! < $1.remainingPercent! }),
              let result = UsageForecaster.forecast(history: history, snapshot: snapshot, window: window,
                                                    bucketID: bucket.id, planType: bucket.planType) else {
            print("LIVE: forecast unavailable")
            return
        }
        print("LIVE: \(history.events.count) token deltas, \(history.quotaSamples.count) quota samples, \(result.windowLabel), remaining=\(window.remainingPercent!)%")
        print("LIVE: overall hours=\(result.overallHours.map { String(format: "%.2f", $0) } ?? "unavailable"), sample hours=\(String(format: "%.2f", result.overallSampleHours)), reset in=\(String(format: "%.2f", result.hoursUntilReset)) hours")
        for row in result.models.prefix(8) {
            print("LIVE: \(row.model): tokens=\(Int(row.recentTokens)), clean blocks=\(row.sampleCount), sampled hours=\(String(format: "%.2f", row.sampledHours)), runway hours=\(row.hours.map { String(format: "%.2f", $0) } ?? "unavailable"), tokens left=\(row.remainingTokens.map { String(Int($0)) } ?? "unavailable")")
        }
    }

    static func main() throws {
        testCleanCalibration()
        testDifferentModels()
        testMixedAndUnknown()
        testZeroChangeAndGaps()
        testResetDriftAndDrop()
        testGuardsAndOrdering()
        print("PASS: \(assertions) forecast assertions covering calibration, model attribution, idle time, resets, uncertainty, and freshness")
        if CommandLine.arguments.contains("--live") {
            do { try liveSummary() }
            catch {
                print("LIVE: validation unavailable: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
