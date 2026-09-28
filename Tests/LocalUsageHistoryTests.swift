import Foundation

@main
struct LocalUsageHistoryTests {
    static let formatter = ISO8601DateFormatter()

    static func main() throws {
        try testModernAndQuotaMetadata()
        try testLegacyAndForks()
        try testCacheAndStreaming()
        if CommandLine.arguments.contains("--live") {
            let reader = LocalUsageHistoryReader()
            let began = Date()
            let history = try reader.read()
            print("LIVE metadata: \(history.events.count) events, \(history.quotaSamples.count) quota samples, scan \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
            print("Model requests: \(Dictionary(grouping: history.events, by: \.model).mapValues(\.count))")
            let warm = Date()
            let second = try reader.read()
            print("Warm scan: \(String(format: "%.2f", Date().timeIntervalSince(warm)))s; \(second.events.count) events; incomplete=\(history.warning != nil)")
        }
        print("PASS: local metadata parsing, request deduplication, fork exclusion, legacy deltas, quotas, streaming, cache")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func fixture(_ action: (URL, Date) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-local-history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root, Date())
    }

    static func line(_ type: String, _ payload: [String: Any], at: Date) -> String {
        let object: [String: Any] = ["type": type, "timestamp": formatter.string(from: at), "payload": payload]
        // Preserve the outer header ahead of payload: production JSONL uses
        // this order, and irrelevant payloads may be many megabytes long.
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "{\"timestamp\":\"\(object["timestamp"]!)\",\"type\":\"\(type)\",\"payload\":\(String(decoding: data, as: UTF8.self))}\n"
    }

    static func meta(_ id: String, at: Date, fork: String? = nil) -> String {
        var payload: [String: Any] = ["id": id]
        if let fork { payload["forked_from_id"] = fork }
        return line("session_meta", payload, at: at)
    }

    static func context(_ model: String, turn: String, at: Date) -> String {
        line("turn_context", ["model": model, "turn_id": turn], at: at)
    }

    static func tokens(_ input: Int, _ cached: Int = 0, _ output: Int = 10) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": output]
    }

    static func request(_ id: String, owner: String, turn: String, input: Int = 100, at: Date) -> String {
        line("token_usage_record", ["response_id": id, "thread_id": owner, "turn_id": turn,
                                    "usage": tokens(input, input / 2)], at: at)
    }

    static func legacy(_ input: Int, _ output: Int, at: Date, last: Bool = false) -> String {
        let usage = tokens(input, 0, output)
        var info: [String: Any] = ["total_token_usage": usage]
        if last { info["last_token_usage"] = usage }
        // token_count normally puts type first; explicit serialization avoids
        // placing a potentially large info object before its subtype header.
        let value = String(decoding: try! JSONSerialization.data(withJSONObject: info), as: UTF8.self)
        return "{\"timestamp\":\"\(formatter.string(from: at))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":\(value)}}\n"
    }

    static func quota(at: Date) -> String {
        "{\"timestamp\":\"\(formatter.string(from: at))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"limit_id\":\"codex\",\"plan_type\":\"pro\",\"primary\":{\"used_percent\":32,\"window_minutes\":10080,\"resets_at\":1791066715},\"secondary\":{\"used_percent\":4,\"window_minutes\":300,\"resets_at\":1791060000}}}}\n"
    }

    static func write(_ text: String, _ name: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func testModernAndQuotaMetadata() throws {
        try fixture { root, now in
            let old = now.addingTimeInterval(-8 * 86_400)
            let recent = now.addingTimeInterval(-60)
            var text = meta("s1", at: old)
            text += context("model-a", turn: "a", at: old)
            text += context("model-b", turn: "b", at: recent)
            text += request("old", owner: "s1", turn: "a", at: old)
            text += legacy(10_000, 100, at: recent, last: true)
            text += request("r1", owner: "s1", turn: "a", at: recent)
            text += request("r1", owner: "s1", turn: "a", at: recent)
            text += request("foreign", owner: "other", turn: "b", at: recent)
            text += request("r2", owner: "s1", turn: "b", input: 200, at: recent)
            text += quota(at: recent)
            _ = try write(text, "sessions/a.jsonl", root: root)
            _ = try write(meta("s2", at: old) + context("model-a", turn: "a", at: old) + request("r1", owner: "s2", turn: "a", at: recent), "archived_sessions/b.jsonl", root: root)
            let history = try LocalUsageHistoryReader(root: root).read(now: now)
            expect(history.events.count == 2, "Modern records replace legacy and deduplicate globally; foreign/old skipped")
            expect(history.events.map(\.totalTokens).sorted() == [110, 210], "Input/output counted once; reasoning not added")
            expect(history.events.first(where: { $0.inputTokens == 100 })?.model == "model-a", "Turn-ID lookup beats latest model")
            expect(history.events.first(where: { $0.inputTokens == 200 })?.cachedInputTokens == 100, "Cached input remains subset")
            expect(history.quotaSamples.count == 2, "Rate-limit-only records preserve both windows")
            expect(Set(history.quotaSamples.map(\.windowMinutes)) == [300, 10_080], "Window durations retained independently")
        }
    }

    static func testLegacyAndForks() throws {
        try fixture { root, now in
            let at = now.addingTimeInterval(-100)
            var text = meta("legacy", at: at) + context("model-a", turn: "a", at: at)
            text += legacy(100, 10, at: at) // Unknown first baseline is excluded.
            text += legacy(200, 20, at: at.addingTimeInterval(1))
            text += legacy(200, 20, at: at.addingTimeInterval(2))
            text += legacy(50, 5, at: at.addingTimeInterval(3)) // Ambiguous decrease excluded.
            text += legacy(0, 0, at: at.addingTimeInterval(4)) // Explicit zero reset.
            text += legacy(100, 10, at: at.addingTimeInterval(5))
            _ = try write(text, "sessions/legacy.jsonl", root: root)
            _ = try write(text, "archived_sessions/duplicate.jsonl", root: root)
            let fork = meta("fork", at: at, fork: "legacy") + context("model-a", turn: "a", at: at)
                + legacy(999, 99, at: at, last: true) + quota(at: at)
            _ = try write(fork, "sessions/fork.jsonl", root: root)
            let modernFork = meta("modern-fork", at: at, fork: "legacy") + context("model-b", turn: "b", at: at)
                + quota(at: at) + request("fork-r1", owner: "modern-fork", turn: "b", at: at.addingTimeInterval(10))
                + quota(at: at.addingTimeInterval(20))
            _ = try write(modernFork, "sessions/modern-fork.jsonl", root: root)
            let history = try LocalUsageHistoryReader(root: root).read(now: now)
            expect(history.events.count == 3, "Two conservative legacy deltas plus owned modern fork request")
            expect(history.events.reduce(0) { $0 + $1.totalTokens } == 330, "Copies, unknown reset, inherited legacy excluded")
            expect(history.quotaSamples.count == 2, "Only fork quota samples after an owned request retained")
            expect(history.warning != nil, "Ambiguous exclusions surfaced")
        }
    }

    static func testCacheAndStreaming() throws {
        try fixture { root, now in
            let at = now.addingTimeInterval(-60)
            let reader = LocalUsageHistoryReader(root: root)
            var text = meta("stream", at: at) + context("model-a", turn: "a", at: at)
            text += "{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 3_000_000) + "\"}\n"
            text += request("r1", owner: "stream", turn: "a", at: at)
            let path = try write(text, "sessions/stream.jsonl", root: root)
            // APFS modification timestamps retain finer precision than the
            // setAttributes API on some OS versions. Use an exact second.
            let modified = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
            let first = try reader.read(now: now)
            expect(first.events.count == 1 && first.warning == nil, "Huge irrelevant line streamed without metadata warning")
            let changed = text.replacingOccurrences(of: "model-a", with: "model-b")
            try changed.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
            expect(try reader.read(now: now).events.first?.model == "model-a", "Unchanged size/mtime cache reused")
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(2)], ofItemAtPath: path.path)
            expect(try reader.read(now: now).events.first?.model == "model-b", "Changed file reparsed")
            let extra = request("r2", owner: "stream", turn: "a", at: at.addingTimeInterval(1))
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(extra.dropLast().utf8))
            try handle.close()
            expect(try reader.read(now: now).events.count == 1, "In-flight final line ignored")
            let append = try FileHandle(forWritingTo: path)
            try append.seekToEnd(); try append.write(contentsOf: Data([10])); try append.close()
            expect(try reader.read(now: now).events.count == 2, "Completed append read on next refresh")
            expect(try reader.read(now: now.addingTimeInterval(8 * 86_400)).events.isEmpty, "Cache ages out with lookback")
        }
    }
}
