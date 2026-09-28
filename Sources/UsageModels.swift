import Foundation

struct UsageWindow: Codable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    /// Missing usage remains unknown; the service's percentage is consumption.
    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }

    var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Usage window" }
        if minutes == 10_080 { return "Weekly" }
        if minutes == 1_440 { return "Daily" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

struct UsageBucket: Codable, Equatable {
    let id: String
    let name: String?
    let planType: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?
}

struct UsageSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let buckets: [UsageBucket]
    let availableResets: Int?
    let ordinaryUsageAllowed: Bool?
}

/// Intentionally decodes only usage fields. Account identifiers, credentials,
/// server diagnostics, and unrelated notifications are never stored.
enum UsageResponseDecoder {
    private struct RateLimits: Decodable {
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: UsageWindow?
        let secondary: UsageWindow?

        func bucket(id: String) -> UsageBucket {
            UsageBucket(id: id, name: limitName, planType: planType,
                        primary: primary, secondary: secondary)
        }
    }

    private struct ResetCredits: Decodable {
        let availableCount: Int?
    }

    private struct Response: Decodable {
        let rateLimits: RateLimits?
        let rateLimitsByLimitId: [String: RateLimits]?
        let rateLimitResetCredits: ResetCredits?
        let ordinaryUsageAllowed: Bool?
    }

    static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let buckets: [UsageBucket]
        if let limits = response.rateLimitsByLimitId, !limits.isEmpty {
            // Main Codex quota first; other metered buckets retain stable ordering.
            buckets = limits.keys.sorted { lhs, rhs in
                if lhs == "codex" { return rhs != "codex" }
                if rhs == "codex" { return false }
                return lhs < rhs
            }.compactMap { id in limits[id]?.bucket(id: id) }
        } else if let limits = response.rateLimits {
            buckets = [limits.bucket(id: limits.limitId ?? "codex")]
        } else {
            buckets = []
        }
        return UsageSnapshot(fetchedAt: fetchedAt, buckets: buckets,
                             availableResets: response.rateLimitResetCredits?.availableCount,
                             ordinaryUsageAllowed: response.ordinaryUsageAllowed)
    }
}
