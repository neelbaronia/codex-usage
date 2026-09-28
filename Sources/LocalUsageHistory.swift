import Foundation
import Darwin

struct LocalUsageEvent: Equatable {
    let timestamp: Date
    let model: String
    /// Inclusive input, with cachedInputTokens retained as a subset.
    let inputTokens: Double
    let cachedInputTokens: Double
    let outputTokens: Double
    var totalTokens: Double { inputTokens + outputTokens }
}

struct LocalQuotaSample: Equatable {
    let timestamp: Date
    let limitID: String
    let windowMinutes: Int
    let resetsAt: TimeInterval
    let usedPercent: Double
    let planType: String?
}

struct LocalUsageHistory {
    let events: [LocalUsageEvent]
    let quotaSamples: [LocalQuotaSample]
    let scannedAt: Date
    let lookbackStart: Date
    let warning: String?
}

/// Synchronous, read-only reader. Call on the app's background refresh queue.
/// Only numerical usage and model/request identity metadata survive parsing.
/// Unchanged files are cached in memory; no history database is written.
final class LocalUsageHistoryReader {
    private let root: URL
    private var cache: [String: CachedFile] = [:]
    private let lock = NSLock()
    private let fractionalDate = ISO8601DateFormatter()
    private let wholeDate = ISO8601DateFormatter()

    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeDate.formatOptions = [.withInternetDateTime]
    }

    func read(now: Date = Date()) throws -> LocalUsageHistory {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var candidates: [(URL, Int, Date)] = []
        var unreadable = false
        var foundDirectory = false
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            foundDirectory = true
            guard let iterator = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in unreadable = true; return true }) else {
                unreadable = true
                continue
            }
            for case let url as URL in iterator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate, let size = values.fileSize else { continue }
                if modified >= cutoff { candidates.append((url, size, modified)) }
            }
        }
        let currentPaths = Set(candidates.map { $0.0.path })
        cache = cache.filter { currentPaths.contains($0.key) }
        var sessions: [String: ParsedFile] = [:]
        var incomplete = false
        for (url, size, modified) in candidates.sorted(by: { $0.0.path < $1.0.path }) {
            let parsed: ParsedFile
            if let entry = cache[url.path], entry.size == size, entry.modified == modified,
               entry.cutoff <= cutoff {
                parsed = entry.parsed
            } else {
                do {
                    parsed = try parse(url: url, size: size, cutoff: cutoff)
                    cache[url.path] = CachedFile(size: size, modified: modified, cutoff: cutoff, parsed: parsed)
                } catch {
                    unreadable = true
                    cache.removeValue(forKey: url.path)
                    continue
                }
            }
            incomplete = incomplete || parsed.incomplete
            // Active/archive copies of the same session can overlap. Keep the
            // fuller observed file, never add legacy cumulative streams twice.
            if let old = sessions[parsed.sessionID], old.recordCount >= parsed.recordCount { continue }
            sessions[parsed.sessionID] = parsed
        }
        var seenResponses = Set<String>()
        var seenQuotas = Set<QuotaIdentity>()
        var events: [LocalUsageEvent] = []
        var quotas: [LocalQuotaSample] = []
        for parsed in sessions.values {
            for entry in parsed.events where entry.event.timestamp >= cutoff && entry.event.timestamp <= now {
                if let response = entry.responseID, !seenResponses.insert(response).inserted { continue }
                events.append(entry.event)
            }
            for sample in parsed.quotas where sample.timestamp >= cutoff && sample.timestamp <= now {
                if seenQuotas.insert(QuotaIdentity(sample)).inserted { quotas.append(sample) }
            }
        }
        events.sort { $0.timestamp < $1.timestamp }
        quotas.sort { $0.timestamp < $1.timestamp }
        let warning: String?
        if !foundDirectory {
            warning = "No local Codex usage history is available yet."
        } else if unreadable || incomplete {
            warning = "Some local usage records were unavailable or ambiguous; estimates may be incomplete."
        } else {
            warning = nil
        }
        return LocalUsageHistory(events: events, quotaSamples: quotas, scannedAt: now,
                                 lookbackStart: cutoff, warning: warning)
    }

    private struct CachedFile {
        let size: Int
        let modified: Date
        let cutoff: Date
        let parsed: ParsedFile
    }

    private struct IdentifiedEvent {
        let event: LocalUsageEvent
        let responseID: String?
    }

    private struct ParsedFile {
        let sessionID: String
        let recordCount: Int
        let events: [IdentifiedEvent]
        let quotas: [LocalQuotaSample]
        let incomplete: Bool
    }

    private struct QuotaIdentity: Hashable {
        let timestamp: Date
        let limitID: String
        let windowMinutes: Int
        let resetsAt: Double
        let usedPercent: Double
        let planType: String?

        init(_ sample: LocalQuotaSample) {
            timestamp = sample.timestamp; limitID = sample.limitID
            windowMinutes = sample.windowMinutes; resetsAt = sample.resetsAt
            usedPercent = sample.usedPercent; planType = sample.planType
        }
    }

    private struct Tokens: Equatable, Hashable {
        let input: Double
        let cached: Double
        let output: Double

        static let zero = Tokens(input: 0, cached: 0, output: 0)

        func subtracting(_ previous: Tokens) -> Tokens? {
            guard input >= previous.input, cached >= previous.cached, output >= previous.output else { return nil }
            let result = Tokens(input: input - previous.input, cached: cached - previous.cached, output: output - previous.output)
            return result.cached <= result.input ? result : nil
        }

        func event(at date: Date, model: String) -> LocalUsageEvent {
            LocalUsageEvent(timestamp: date, model: model, inputTokens: input,
                            cachedInputTokens: cached, outputTokens: output)
        }
    }

    private func parse(url: URL, size: Int, cutoff: Date) throws -> ParsedFile {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var metadataSeen = false
        var isFork = false
        var startedAt: Date?
        var model = "unknown"
        var turnModels: [String: String] = [:]
        var modern: [IdentifiedEvent] = []
        var legacy: [IdentifiedEvent] = []
        var quotas: [LocalQuotaSample] = []
        var modernSeen = false
        var firstOwnedRequestAt: Date?
        var previous: Tokens?
        var seenLegacy = Set<Tokens>()
        var seenResponses = Set<String>()
        var recordCount = 0
        var incomplete = false
        var legacyIncomplete = false

        try MetadataLines.read(url: url, byteLimit: size) { data in
            guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any] else {
                incomplete = true
                return
            }
            let timestamp = self.date(record["timestamp"])
            if type == "session_meta" {
                if !metadataSeen {
                    sessionID = self.identifier(payload["id"]) ?? self.identifier(payload["session_id"]) ?? sessionID
                    isFork = self.identifier(payload["forked_from_id"]) != nil
                    startedAt = self.date(payload["timestamp"]) ?? timestamp
                    metadataSeen = true
                }
                return
            }
            if type == "turn_context" {
                model = self.identifier(payload["model"]) ?? "unknown"
                if let turn = self.identifier(payload["turn_id"]) { turnModels[turn] = model }
                return
            }
            guard let timestamp else { return }
            if type == "token_usage_record" {
                let owner = self.identifier(payload["thread_id"])
                if let owner, owner != sessionID { return }
                if isFork && owner == nil { incomplete = true; return }
                guard let tokens = self.tokens(payload["usage"]) else {
                    if timestamp >= cutoff { incomplete = true }
                    return
                }
                if !modernSeen && !legacy.isEmpty {
                    // Some versions flush the snapshot immediately before its
                    // first request record. That one exact snapshot is a
                    // duplicate; an older/larger legacy tail is unaccounted
                    // history that cannot safely calibrate a model's quota.
                    let snapshotFirst = legacy.count == 1 && legacy[0].event.inputTokens == tokens.input
                        && legacy[0].event.cachedInputTokens == tokens.cached
                        && legacy[0].event.outputTokens == tokens.output
                        && abs(legacy[0].event.timestamp.timeIntervalSince(timestamp)) <= 2
                    if !snapshotFirst { incomplete = true }
                }
                modernSeen = true
                if firstOwnedRequestAt == nil { firstOwnedRequestAt = timestamp }
                recordCount += 1
                guard timestamp >= cutoff, tokens.input + tokens.output > 0 else { return }
                guard let response = self.identifier(payload["response_id"]) else {
                    // Without request identity we cannot prove cross-file
                    // deduplication, so do not calibrate from this record.
                    incomplete = true
                    return
                }
                guard seenResponses.insert(response).inserted else { return }
                let selectedModel = self.identifier(payload["turn_id"]).flatMap { turnModels[$0] } ?? model
                modern.append(IdentifiedEvent(event: tokens.event(at: timestamp, model: selectedModel), responseID: response))
                return
            }
            guard type == "event_msg", payload["type"] as? String == "token_count" else { return }
            recordCount += 1
            // Rate-limit-only records are useful even when info is null.
            if timestamp >= cutoff, let limits = payload["rate_limits"] as? [String: Any] {
                for key in ["primary", "secondary"] {
                    guard let window = limits[key] as? [String: Any],
                          let used = self.number(window["used_percent"]), used >= 0,
                          let duration = self.number(window["window_minutes"]), duration > 0,
                          duration.rounded(.towardZero) == duration, duration < Double(Int.max),
                          let reset = self.number(window["resets_at"]), reset > 0 else { continue }
                    quotas.append(LocalQuotaSample(timestamp: timestamp,
                                                   limitID: self.identifier(limits["limit_id"]) ?? "codex",
                                                   windowMinutes: Int(duration), resetsAt: reset,
                                                   usedPercent: used, planType: self.identifier(limits["plan_type"])))
                }
            }
            // Once request accounting starts, legacy counters have a different
            // lifecycle (notably around compaction) and are never compared.
            guard !modernSeen, let info = payload["info"] as? [String: Any],
                  let current = self.tokens(info["total_token_usage"]) else { return }
            // Keep the legacy stream independent of request counters. Its
            // records are used only if the entire file has no owned requests.
            if current == .zero {
                previous = .zero; seenLegacy.removeAll(); seenLegacy.insert(.zero)
                return
            }
            guard seenLegacy.insert(current).inserted else { return }
            let delta: Tokens?
            if let baseline = previous {
                delta = current.subtracting(baseline)
                if delta == nil && timestamp >= cutoff { legacyIncomplete = true }
            } else {
                // A first snapshot can include an unknown past. Count it only
                // when last_token_usage proves this was exactly one request.
                delta = self.tokens(info["last_token_usage"]) == current ? current : nil
                if delta == nil && timestamp >= cutoff { legacyIncomplete = true }
            }
            previous = current
            guard let delta, timestamp >= cutoff, delta.input + delta.output > 0 else { return }
            legacy.append(IdentifiedEvent(event: delta.event(at: timestamp, model: model), responseID: nil))
        } onOversizedMetadata: {
            incomplete = true
        }
        let events: [IdentifiedEvent]
        if modernSeen {
            events = modern
        } else if isFork {
            if !legacy.isEmpty { incomplete = true }
            events = []
        } else {
            events = legacy
            incomplete = incomplete || legacyIncomplete
        }
        if isFork {
            // Copied fork history can include account snapshots from its
            // parent. Retain only samples after a proven owned request.
            if let firstOwnedRequestAt {
                let boundary = max(firstOwnedRequestAt, startedAt ?? firstOwnedRequestAt)
                quotas = quotas.filter { $0.timestamp >= boundary }
            } else {
                quotas = []
            }
        }
        return ParsedFile(sessionID: sessionID, recordCount: recordCount, events: events,
                          quotas: quotas, incomplete: incomplete)
    }

    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private func tokens(_ value: Any?) -> Tokens? {
        guard let object = value as? [String: Any],
              let input = number(object["input_tokens"]), input >= 0,
              let output = number(object["output_tokens"]), output >= 0 else { return nil }
        let cached: Double
        if object["cached_input_tokens"] == nil || object["cached_input_tokens"] is NSNull {
            cached = 0
        } else if let value = number(object["cached_input_tokens"]), value >= 0, value <= input {
            cached = value
        } else { return nil }
        guard (input + output).isFinite else { return nil }
        return Tokens(input: input, cached: cached, output: output)
    }

    private func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0) }) else { return nil }
        return value
    }

    private func date(_ value: Any?) -> Date? {
        guard let value = value as? String, value.count <= 40 else { return nil }
        return fractionalDate.date(from: value) ?? wholeDate.date(from: value)
    }
}

private enum MetadataLines {
    private static let outerType = try! NSRegularExpression(pattern: #""type"\s*:\s*"([^"]+)""#)
    private static let interesting = Set(["session_meta", "turn_context", "token_usage_record", "event_msg"])

    /// Streams snapshot-sized chunks, discarding irrelevant lines as soon as
    /// their outer type is known. Huge tool/prompt lines never accumulate.
    static func read(url: URL, byteLimit: Int, visit: (Data) -> Void,
                     onOversizedMetadata: () -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = byteLimit
        var line = Data()
        var discard = false
        var selected = false
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: min(262_144, remaining)), !chunk.isEmpty else { break }
            remaining -= chunk.count
            chunk.withUnsafeBytes { raw in
                guard let start = raw.baseAddress else { return }
                var offset = 0
                while offset < chunk.count {
                    let cursor = start.advanced(by: offset)
                    let newline = memchr(cursor, 10, chunk.count - offset)
                    let count = newline.map { cursor.distance(to: $0) } ?? (chunk.count - offset)
                    if !discard {
                        // Inspect only a short prefix before retaining a line.
                        if !selected {
                            let prefixCount = min(count, max(0, 1_024 - line.count))
                            if prefixCount > 0 { line.append(cursor.assumingMemoryBound(to: UInt8.self), count: prefixCount) }
                            switch kind(line) {
                            case .some(let keep): selected = keep; discard = !keep
                            case .none:
                                if line.count >= 1_024 { discard = true }
                            }
                            if selected && count > prefixCount {
                                if line.count + count - prefixCount > 2_097_152 {
                                    discard = true; onOversizedMetadata()
                                } else {
                                    line.append(cursor.advanced(by: prefixCount).assumingMemoryBound(to: UInt8.self), count: count - prefixCount)
                                }
                            }
                        } else if line.count + count <= 2_097_152 {
                            line.append(cursor.assumingMemoryBound(to: UInt8.self), count: count)
                        } else {
                            discard = true; onOversizedMetadata()
                        }
                    }
                    if newline != nil {
                        if selected && !discard && !line.isEmpty { visit(line) }
                        line.removeAll(keepingCapacity: true)
                        discard = false; selected = false
                        offset += count + 1
                    } else {
                        offset += count
                    }
                }
            }
        }
        // An unterminated final line may be in flight. Retry after file change.
    }

    private static func kind(_ prefix: Data) -> Bool? {
        guard let text = String(data: prefix, encoding: .utf8) else {
            // A split UTF-8 code point may occur later in a line; its ASCII
            // header is still sufficient for type classification.
            return kindASCII(prefix)
        }
        guard let match = outerType.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let type = String(text[range])
        if type == "event_msg" {
            // Wait for the complete payload type, including when its value
            // happens to cross a chunk boundary.
            let rest = NSRange(range.upperBound..<text.endIndex, in: text)
            guard let subtype = outerType.firstMatch(in: text, range: rest),
                  let subtypeRange = Range(subtype.range(at: 1), in: text) else { return nil }
            return text[subtypeRange] == "token_count"
        }
        return interesting.contains(type)
    }

    private static func kindASCII(_ prefix: Data) -> Bool? {
        let bytes = prefix.prefix(256).map { $0 < 128 ? $0 : UInt8(32) }
        return kind(Data(bytes))
    }
}
