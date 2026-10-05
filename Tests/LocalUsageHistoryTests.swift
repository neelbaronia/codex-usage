import Foundation

@main
struct LocalUsageHistoryTests {
    static let formatter = ISO8601DateFormatter()

    static func main() throws {
        try testModernAndQuotaMetadata()
        try testLegacyAndForks()
        try testCacheAndStreaming()
        try testRepositoryAttribution()
        try testMissingTurnRepository()
        try testInvalidTokenCounters()
        try testWideningHistory()
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
        print("PASS: local metadata parsing, request deduplication, fork exclusion, legacy deltas, quotas, streaming, repository attribution, missing turn directories, valid token counters, widening cache")
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

    static func meta(_ id: String, at: Date, fork: String? = nil, cwd: String? = nil) -> String {
        var payload: [String: Any] = ["id": id]
        if let fork { payload["forked_from_id"] = fork }
        if let cwd { payload["cwd"] = cwd }
        return line("session_meta", payload, at: at)
    }

    static func context(_ model: String, turn: String, at: Date, cwd: String? = nil) -> String {
        var payload: [String: Any] = ["model": model, "turn_id": turn]
        if let cwd { payload["cwd"] = cwd }
        return line("turn_context", payload, at: at)
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

    static func testRepositoryAttribution() throws {
        try fixture { root, now in
            let manager = FileManager.default
            let first = root.appendingPathComponent("projects/one/shared")
            let second = root.appendingPathComponent("projects/two/shared")
            let worktree = first.appendingPathComponent("nested-worktree")
            let loose = root.appendingPathComponent("not-a-repository")
            for directory in [first.appendingPathComponent("Sources/Subdir"), second, worktree, loose] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try manager.createDirectory(at: first.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try manager.createDirectory(at: second.appendingPathComponent(".git"), withIntermediateDirectories: true)
            // A worktree .git file is a root marker; its content is never read.
            try "gitdir: unused-fixture-metadata\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            let alias = root.appendingPathComponent("project-alias")
            try manager.createSymbolicLink(at: alias, withDestinationURL: first)
            let at = now.addingTimeInterval(-60)
            var text = meta("repos", at: at, cwd: first.appendingPathComponent("Sources/Subdir").path)
            text += context("model-a", turn: "first", at: at)
            text += context("model-b", turn: "second", at: at, cwd: second.path)
            text += request("r-first", owner: "repos", turn: "first", input: 100, at: at)
            text += request("r-second", owner: "repos", turn: "second", input: 200, at: at)
            text += context("model-a", turn: "nested", at: at, cwd: worktree.path)
            text += request("r-nested", owner: "repos", turn: "nested", input: 300, at: at)
            text += context("model-a", turn: "alias", at: at, cwd: alias.appendingPathComponent("Sources/../Sources").path)
            text += request("r-alias", owner: "repos", turn: "alias", input: 400, at: at)
            text += context("model-a", turn: "loose", at: at, cwd: loose.path)
            text += request("r-loose", owner: "repos", turn: "loose", input: 500, at: at)
            _ = try write(text, "sessions/repos.jsonl", root: root)
            _ = try write(text, "archived_sessions/repos-copy.jsonl", root: root)
            let unknown = meta("unknown", at: at, cwd: "relative/path") + context("model-a", turn: "x", at: at)
                + request("r-unknown", owner: "unknown", turn: "x", input: 600, at: at)
            _ = try write(unknown, "sessions/unknown.jsonl", root: root)
            let legacyText = meta("repo-legacy", at: at, cwd: second.path) + context("model-a", turn: "l", at: at)
                + legacy(700, 10, at: at, last: true)
            _ = try write(legacyText, "sessions/legacy-repo.jsonl", root: root)
            let history = try LocalUsageHistoryReader(root: root).read(now: now)
            let paths = Dictionary(uniqueKeysWithValues: history.events.map { ($0.inputTokens, $0.repositoryPath) })
            func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
            expect(history.events.count == 7, "Archive copies remain deduplicated with repository metadata")
            expect(paths[100] == canonical(first), "Nearest .git ancestor and turn-ID attribution beat latest cwd")
            expect(paths[200] == canonical(second), "Same-name roots retain separate full paths")
            expect(paths[300] == canonical(worktree), "Nested worktree .git file stops ancestor lookup")
            expect(paths[400] == canonical(first), "Symlink and dot components normalize to the same repository")
            expect(paths[500] == canonical(loose), "Non-repository usage retains its logged directory")
            expect(history.events.first { $0.inputTokens == 600 }?.repositoryPath == nil, "Relative cwd remains unattributed")
            expect(paths[700] == canonical(second), "Legacy metadata also retains repository attribution")
        }
    }

    static func testMissingTurnRepository() throws {
        try fixture { root, now in
            let at = now.addingTimeInterval(-60)
            let directory = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var text = meta("missing-cwd", at: at)
            text += context("model-a", turn: "unknown-early", at: at)
            text += context("model-b", turn: "known", at: at, cwd: directory.path)
            text += request("unknown-delayed", owner: "missing-cwd", turn: "unknown-early", input: 100, at: at)
            text += request("known", owner: "missing-cwd", turn: "known", input: 200, at: at)
            text += context("model-a", turn: "unknown-later", at: at)
            text += request("unknown-later", owner: "missing-cwd", turn: "unknown-later", input: 300, at: at)
            text += request("known-delayed", owner: "missing-cwd", turn: "known", input: 400, at: at)
            _ = try write(text, "sessions/missing-cwd.jsonl", root: root)
            let events = try LocalUsageHistoryReader(root: root).read(now: now).events
            expect(events.count == 4, "All owned requests survive unknown repository metadata")
            expect(events.filter { $0.inputTokens == 100 || $0.inputTokens == 300 }.allSatisfy { $0.repositoryPath == nil },
                   "Missing turn cwd stays unknown before and after a known repository, including delayed usage")
            let canonical = directory.standardizedFileURL.resolvingSymlinksInPath().path
            expect(events.filter { $0.inputTokens == 200 || $0.inputTokens == 400 }.allSatisfy { $0.repositoryPath == canonical },
                   "Delayed requests keep their known turn's repository")
        }
    }

    static func testInvalidTokenCounters() throws {
        try fixture { root, now in
            let at = now.addingTimeInterval(-60)
            var text = meta("counters", at: at) + context("model-a", turn: "a", at: at)
            let invalid: [[String: Any]] = [
                ["input_tokens": 1e100, "cached_input_tokens": 0, "output_tokens": 10],
                ["input_tokens": 9_007_199_254_740_992.0, "cached_input_tokens": 0, "output_tokens": 10],
                ["input_tokens": 100.5, "cached_input_tokens": 0, "output_tokens": 10],
                ["input_tokens": 100, "cached_input_tokens": 10.5, "output_tokens": 10],
                ["input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 10.5],
                ["input_tokens": 100, "cached_input_tokens": 101, "output_tokens": 10],
                ["input_tokens": -1, "cached_input_tokens": 0, "output_tokens": 10],
                ["input_tokens": true, "cached_input_tokens": 0, "output_tokens": 10]
            ]
            for (index, usage) in invalid.enumerated() {
                text += line("token_usage_record", ["response_id": "invalid-\(index)", "thread_id": "counters",
                             "turn_id": "a", "usage": usage], at: at)
            }
            text += request("valid-counter", owner: "counters", turn: "a", input: 100, at: at)
            _ = try write(text, "sessions/counters.jsonl", root: root)
            let history = try LocalUsageHistoryReader(root: root).read(now: now)
            expect(history.events.count == 1 && history.events[0].totalTokens == 110,
                   "Only finite nonnegative safe integer counters with cached input as a subset are counted")
            expect(history.warning != nil, "Malformed request counters surface incomplete history")
        }
    }

    static func testWideningHistory() throws {
        try fixture { root, now in
            let recent = now.addingTimeInterval(-86_400)
            let monthly = now.addingTimeInterval(-20 * 86_400)
            let old = now.addingTimeInterval(-40 * 86_400)
            let ancient = now.addingTimeInterval(-60 * 86_400)
            let text = meta("a-stream", at: old) + context("model-a", turn: "a", at: old)
                + request("r-old", owner: "a-stream", turn: "a", at: old)
                + request("r-month", owner: "a-stream", turn: "a", at: monthly)
                + request("r-recent", owner: "a-stream", turn: "a", at: recent)
            _ = try write(text, "sessions/a-stream.jsonl", root: root)
            let oldFile = try write(meta("b-old", at: ancient) + context("model-a", turn: "a", at: ancient)
                + request("r-ancient", owner: "b-old", turn: "a", at: ancient)
                + request("r-old", owner: "b-old", turn: "a", at: old), "archived_sessions/old.jsonl", root: root)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldFile.path)
            let reader = LocalUsageHistoryReader(root: root)
            expect(try reader.read(now: now).events.count == 1, "Default forecast range remains rolling seven days")
            expect(try reader.read(now: now, lookbackDays: 30).events.count == 2, "Wider range reparses an unchanged recent file")
            let all = try reader.read(now: now, lookbackDays: nil)
            expect(all.events.count == 4, "All available includes old-mtime archives and deduplicates responses across files")
            expect(abs(all.lookbackStart.timeIntervalSince(ancient)) < 1, "All-history start is observed activity, not distantPast")
            expect(try reader.read(now: now).events.count == 1, "A wider cached parse filters down to the default range")
            expect(try reader.read(now: now, lookbackDays: nil).events.count == 4, "Widening again preserves all history")
        }
    }
}
