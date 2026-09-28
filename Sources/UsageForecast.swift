import Foundation

struct ModelRunway {
    let model: String
    let recentTokens: Double
    let hours: Double?
    let lowerHours: Double?
    let upperHours: Double?
    let remainingTokens: Double?
    let sampleCount: Int
    let sampledHours: Double
}

struct UsageForecast {
    let windowLabel: String
    let overallHours: Double?
    let overallSampleHours: Double
    let hoursUntilReset: Double
    let models: [ModelRunway]
}

/// Empirical estimates, never an API-price-to-subscription conversion. A quota
/// snapshot is account-wide; the model attached to that event is not attribution.
enum UsageForecaster {
    private struct Block {
        let model: String
        let tokens: Double
        let hours: Double
        let points: Double
    }

    static func forecast(history: LocalUsageHistory, snapshot: UsageSnapshot,
                         window: UsageWindow, bucketID: String = "codex",
                         planType: String? = nil, now: Date = Date()) -> UsageForecast? {
        guard let remaining = window.remainingPercent,
              let reset = window.resetsAt, reset.isFinite, reset > now.timeIntervalSince1970,
              let duration = window.windowDurationMins, duration > 0,
              snapshot.fetchedAt <= now, history.scannedAt <= now,
              now.timeIntervalSince(snapshot.fetchedAt) <= 600,
              now.timeIntervalSince(history.scannedAt) <= 900,
              snapshot.ordinaryUsageAllowed != false else { return nil }
        let cutoff = max(history.lookbackStart, now.addingTimeInterval(-7 * 86400))
        let events = history.events.filter {
            $0.timestamp >= cutoff && $0.timestamp <= now && $0.totalTokens.isFinite && $0.totalTokens > 0
        }.sorted { $0.timestamp < $1.timestamp }
        var samples = history.quotaSamples.filter {
            $0.timestamp >= cutoff && $0.timestamp <= now && $0.limitID == bucketID &&
            $0.windowMinutes == duration && $0.planType == planType &&
            $0.resetsAt.isFinite && $0.timestamp.timeIntervalSince1970 < $0.resetsAt &&
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
        }
        samples.append(LocalQuotaSample(timestamp: snapshot.fetchedAt, limitID: bucketID,
                                       windowMinutes: duration, resetsAt: reset,
                                       usedPercent: 100 - remaining, planType: planType))
        samples.sort { $0.timestamp == $1.timestamp ? $0.usedPercent < $1.usedPercent : $0.timestamp < $1.timestamp }

        // Reset timestamps in real logs drift by a few seconds/minutes. Keep a
        // continuous segment only while timestamps agree within ten minutes and
        // the meter is monotonic. A quota drop breaks calibration (banked reset,
        // stale interleaved snapshot, plan change), even with the same reset date.
        var segments: [[LocalQuotaSample]] = []
        for sample in samples {
            if let last = segments.last?.last,
               abs(sample.resetsAt - last.resetsAt) <= 600,
               sample.usedPercent >= last.usedPercent,
               sample.timestamp > last.timestamp {
                segments[segments.count - 1].append(sample)
            } else if let last = segments.last?.last,
                      sample.timestamp == last.timestamp && sample.usedPercent == last.usedPercent &&
                      abs(sample.resetsAt - last.resetsAt) <= 600 {
                continue
            } else { segments.append([sample]) }
        }

        var blocks: [Block] = []
        // Omitted/ambiguous model activity could make a mixed interval appear
        // attributable to one model. Account-wide meter pace remains usable.
        for segment in segments where history.warning == nil {
            guard var anchor = segment.first else { continue }
            for end in segment.dropFirst() {
                let elapsed = end.timestamp.timeIntervalSince(anchor.timestamp)
                // Retain zero-change periods; otherwise the inferred burn rate
                // is biased upward. Discard long gaps rather than infer activity.
                if elapsed > 3 * 3600 { anchor = end; continue }
                let delta = end.usedPercent - anchor.usedPercent
                guard elapsed >= 30 * 60, delta >= 2 else { continue }
                let startIndex = lowerBound(events, anchor.timestamp.addingTimeInterval(-60))
                let endIndex = lowerBound(events, end.timestamp.addingTimeInterval(60))
                let guardedEvents = events[startIndex..<endIndex]
                let models = Set(guardedEvents.map(\.model))
                if models.count == 1, let model = models.first, model != "unknown", !model.isEmpty {
                    let intervalEvents = guardedEvents.filter { $0.timestamp > anchor.timestamp && $0.timestamp <= end.timestamp }
                    let tokens = intervalEvents.reduce(0) { $0 + $1.totalTokens }
                    if intervalEvents.count >= 3 && tokens > 0 {
                        blocks.append(Block(model: model, tokens: tokens, hours: elapsed / 3600, points: delta))
                    }
                }
                // Intervals are disjoint even when mixed-model activity prevents
                // attribution; never assign a mixed delta to the last model.
                anchor = end
            }
        }

        let totals = Dictionary(grouping: events, by: \.model).mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
        let byModel = Dictionary(grouping: blocks, by: \.model)
        let models = totals.keys.sorted { totals[$0]! > totals[$1]! }.map { model -> ModelRunway in
            let rows = byModel[model] ?? []
            let points = rows.reduce(0) { $0 + $1.points }
            let tokens = rows.reduce(0) { $0 + $1.tokens }
            let hours = rows.reduce(0) { $0 + $1.hours }
            guard rows.count >= 3, points >= 6, hours >= 1.5 else {
                return ModelRunway(model: model, recentTokens: totals[model]!, hours: nil,
                                   lowerHours: nil, upperHours: nil, remainingTokens: nil,
                                   sampleCount: rows.count, sampledHours: hours)
            }
            // Include +/-1 percentage point per block to reflect meter rounding.
            // These are observed-scenario bounds, not a statistical confidence interval.
            let fastest = rows.map { ($0.points + 1) / $0.hours }.max()!
            let slowest = rows.map { max(0.5, $0.points - 1) / $0.hours }.min()!
            return ModelRunway(model: model, recentTokens: totals[model]!, hours: remaining * hours / points,
                               lowerHours: remaining / fastest, upperHours: remaining / slowest,
                               remainingTokens: remaining * tokens / points,
                               sampleCount: rows.count, sampledHours: hours)
        }

        // Overall account pace includes all activity, even other devices. Only
        // use the live window's latest uninterrupted segment and last 24 hours.
        var overallHours: Double?
        var overallSampleHours: Double = 0
        if let latest = segments.last,
           let end = latest.last, abs(end.resetsAt - reset) <= 600,
           let start = latest.first(where: { $0.timestamp >= now.addingTimeInterval(-86400) }),
           end.timestamp == snapshot.fetchedAt {
            let hours = end.timestamp.timeIntervalSince(start.timestamp) / 3600
            let delta = end.usedPercent - start.usedPercent
            if hours >= 1 && delta >= 2 {
                overallHours = remaining * hours / delta
                overallSampleHours = hours
            }
        }
        return UsageForecast(windowLabel: window.label, overallHours: overallHours,
                             overallSampleHours: overallSampleHours,
                             hoursUntilReset: (reset - now.timeIntervalSince1970) / 3600, models: models)
    }

    private static func lowerBound(_ events: [LocalUsageEvent], _ date: Date) -> Int {
        var low = 0
        var high = events.count
        while low < high {
            let middle = (low + high) / 2
            if events[middle].timestamp < date { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
