import Foundation

enum UsageReportingRange: String, CaseIterable {
    case week, month, all

    var title: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .all: return "All available"
        }
    }

    /// Calendar-day ranges include today and the preceding 6 or 29 local days.
    /// All available starts at the first valid recorded event, never an invented account age.
    func startDate(now: Date, history: LocalUsageHistory) -> Date {
        let calendar = Calendar.current
        switch self {
        case .week, .month:
            return calendar.date(byAdding: .day, value: self == .week ? -6 : -29,
                                 to: calendar.startOfDay(for: now)) ?? now
        case .all:
            let firstEvent = history.events.lazy.filter {
                $0.timestamp.timeIntervalSince1970.isFinite && $0.timestamp <= now
                    && UsageAnalytics.validTokenCount($0.inputTokens)
                    && UsageAnalytics.validTokenCount($0.cachedInputTokens) && $0.cachedInputTokens <= $0.inputTokens
                    && UsageAnalytics.validTokenCount($0.outputTokens) && $0.totalTokens.isFinite && $0.totalTokens > 0
            }.map(\.timestamp).min() ?? now
            return calendar.startOfDay(for: firstEvent)
        }
    }
}

struct ModelUsageTotal {
    let model: String
    let tokens: Double
}

struct RepositoryUsageTotal {
    /// Full normalized path, or "unknown". Display names are not identities.
    let id: String
    let name: String
    let path: String?
    let tokens: Double
    let costUSD: Double
    let pricedTokens: Double
    let unpricedTokens: Double
}

struct DailyUsageTotal {
    /// Midnight in the user's current local calendar, including DST transitions.
    let date: Date
    let tokens: Double
}

struct UsageAnalytics {
    let totalTokens: Double
    /// Inclusive input: cached input is a subset, not an additional token count.
    let inputTokens: Double
    let cachedInputTokens: Double
    let outputTokens: Double
    /// API-equivalent estimate for events with verified model prices only.
    let estimatedCostUSD: Double
    let pricedTokens: Double
    let unpricedTokens: Double
    let models: [ModelUsageTotal]
    let repositories: [RepositoryUsageTotal]
    let days: [DailyUsageTotal]
    let startDate: Date
    let endDate: Date

    static func summarize(_ history: LocalUsageHistory, range: UsageReportingRange,
                          now: Date = Date()) -> UsageAnalytics {
        let start = range.startDate(now: now, history: history)
        let calendar = Calendar.current
        var input = 0.0, cached = 0.0, output = 0.0, cost = 0.0, priced = 0.0, unpriced = 0.0
        var models: [String: Double] = [:]
        var repositories: [String: RepositoryAccumulator] = [:]
        var daily: [Date: Double] = [:]
        for event in history.events {
            guard event.timestamp.timeIntervalSince1970.isFinite, event.timestamp >= start, event.timestamp <= now,
                  validTokenCount(event.inputTokens),
                  validTokenCount(event.cachedInputTokens),
                  event.cachedInputTokens <= event.inputTokens,
                  validTokenCount(event.outputTokens),
                  event.totalTokens.isFinite, event.totalTokens > 0 else { continue }
            input += event.inputTokens
            cached += event.cachedInputTokens
            output += event.outputTokens
            models[event.model, default: 0] += event.totalTokens
            daily[calendar.startOfDay(for: event.timestamp), default: 0] += event.totalTokens

            let estimate = ModelPricing.estimateUSD(model: event.model, inputTokens: event.inputTokens,
                                                   cachedInputTokens: event.cachedInputTokens,
                                                   outputTokens: event.outputTokens)
            let pricedCost = estimate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if let pricedCost {
                cost += pricedCost
                priced += event.totalTokens
            } else {
                unpriced += event.totalTokens
            }
            let path = normalizedPath(event.repositoryPath)
            let id = path ?? "unknown"
            var repository = repositories[id] ?? RepositoryAccumulator(path: path)
            repository.tokens += event.totalTokens
            if let pricedCost {
                repository.cost += pricedCost
                repository.priced += event.totalTokens
            } else {
                repository.unpriced += event.totalTokens
            }
            repositories[id] = repository
        }

        var days: [DailyUsageTotal] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: now)
        while day <= lastDay {
            days.append(DailyUsageTotal(date: day, tokens: daily[day, default: 0]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        var modelRows: [ModelUsageTotal] = []
        for (model, tokens) in models { modelRows.append(ModelUsageTotal(model: model, tokens: tokens)) }
        modelRows.sort { lhs, rhs in
            lhs.tokens == rhs.tokens ? lhs.model < rhs.model : lhs.tokens > rhs.tokens
        }
        var repositoryRows: [RepositoryUsageTotal] = []
        for (id, total) in repositories {
            let name = total.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown repository"
            repositoryRows.append(RepositoryUsageTotal(id: id, name: name.isEmpty ? "/" : name, path: total.path,
                                                       tokens: total.tokens, costUSD: total.cost,
                                                       pricedTokens: total.priced, unpricedTokens: total.unpriced))
        }
        repositoryRows.sort { lhs, rhs in
            let lhsPriced = lhs.pricedTokens > 0, rhsPriced = rhs.pricedTokens > 0
            if lhsPriced != rhsPriced { return lhsPriced }
            if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return lhs.id < rhs.id
        }
        return UsageAnalytics(totalTokens: input + output, inputTokens: input, cachedInputTokens: cached,
                              outputTokens: output, estimatedCostUSD: cost, pricedTokens: priced,
                              unpricedTokens: unpriced, models: modelRows, repositories: repositoryRows,
                              days: days, startDate: start, endDate: now)
    }

    fileprivate static func validTokenCount(_ count: Double) -> Bool {
        count.isFinite && count >= 0 && count <= 9_007_199_254_740_991
            && count.rounded(.towardZero) == count
    }

    private struct RepositoryAccumulator {
        let path: String?
        var tokens = 0.0
        var cost = 0.0
        var priced = 0.0
        var unpriced = 0.0
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 4_096,
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
