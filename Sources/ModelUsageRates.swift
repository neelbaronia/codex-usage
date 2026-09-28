import Foundation

/// Recorded token throughput, not subscription-quota consumption. The same
/// elapsed reporting interval (including idle time) applies to every model.
struct ModelUsageRate {
    let model: String
    let totalTokens: Double
    let inputTokens: Double
    let cachedInputTokens: Double
    let outputTokens: Double
    let elapsedHours: Double

    var tokensPerHour: Double { totalTokens / elapsedHours }
    var tokensPerDay: Double { tokensPerHour * 24 }
}

enum ModelUsageRates {
    static func calculate(history: LocalUsageHistory) -> [ModelUsageRate] {
        guard history.scannedAt.timeIntervalSinceReferenceDate.isFinite,
              history.lookbackStart.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let start = max(history.lookbackStart, history.scannedAt.addingTimeInterval(-7 * 86400))
        let elapsedHours = history.scannedAt.timeIntervalSince(start) / 3600
        guard elapsedHours.isFinite, elapsedHours > 0, elapsedHours <= 168 else { return [] }

        var totals: [String: (input: Double, cached: Double, output: Double)] = [:]
        for event in history.events {
            guard event.timestamp.timeIntervalSinceReferenceDate.isFinite,
                  event.timestamp >= start, event.timestamp <= history.scannedAt,
                  !event.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.inputTokens.isFinite, event.inputTokens >= 0,
                  event.cachedInputTokens.isFinite, event.cachedInputTokens >= 0,
                  event.cachedInputTokens <= event.inputTokens,
                  event.outputTokens.isFinite, event.outputTokens >= 0,
                  event.totalTokens.isFinite, event.totalTokens > 0 else { continue }
            let previous = totals[event.model] ?? (input: 0, cached: 0, output: 0)
            totals[event.model] = (input: previous.input + event.inputTokens,
                                   cached: previous.cached + event.cachedInputTokens,
                                   output: previous.output + event.outputTokens)
        }

        // A partial-history warning affects quota attribution, but recorded
        // token totals remain useful. The UI is responsible for that qualifier.
        return totals.compactMap { model, value -> ModelUsageRate? in
            let rate = ModelUsageRate(model: model, totalTokens: value.input + value.output,
                                      inputTokens: value.input, cachedInputTokens: value.cached,
                                      outputTokens: value.output, elapsedHours: elapsedHours)
            guard rate.totalTokens.isFinite, rate.cachedInputTokens.isFinite,
                  rate.tokensPerHour.isFinite, rate.tokensPerDay.isFinite else { return nil }
            return rate
        }.sorted {
            $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens
        }
    }
}
