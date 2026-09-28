import Foundation
import Darwin

@main
struct UsageProviderTests {
    static func main() throws {
        if CommandLine.arguments.contains("app-server") {
            runFakeServer()
            return
        }
        try testDecoding()
        try testTransport()
        if CommandLine.arguments.contains("--live") {
            // Finder may provide only the macOS system PATH. Check the actual
            // local installation only during this explicitly requested live test.
            expect(CodexExecutableLocator.locate(environment: ["PATH": "/usr/bin:/bin"]) != nil,
                   "GUI executable discovery finds this machine's Codex install")
            let snapshot = try UsageProvider().fetch()
            print("LIVE: \(snapshot.buckets.count) bucket(s)")
            for bucket in snapshot.buckets {
                print("  \(bucket.id): plan=\(bucket.planType ?? "unknown"), primary remaining=\(bucket.primary?.remainingPercent.map { String($0) } ?? "unknown")%, secondary remaining=\(bucket.secondary?.remainingPercent.map { String($0) } ?? "unknown")%")
            }
            print("  available resets=\(snapshot.availableResets.map(String.init) ?? "unknown")")
        }
        print("PASS: usage decoding, transport, sanitized failures, deadline, and child cleanup")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func decode(_ string: String) throws -> UsageSnapshot {
        try UsageResponseDecoder.decode(Data(string.utf8), fetchedAt: Date(timeIntervalSince1970: 123))
    }

    static func testDecoding() throws {
        let snapshot = try decode(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"extra":{"limitName":"Extra","primary":{"usedPercent":110}},"codex":{"planType":"pro","primary":{"usedPercent":32,"windowDurationMins":10080,"resetsAt":1790463600},"secondary":null}},"rateLimitResetCredits":{"availableCount":1},"ordinaryUsageAllowed":false}"#)
        expect(snapshot.buckets.map(\.id) == ["codex", "extra"], "Multi-bucket preferred and Codex first")
        expect(snapshot.buckets[0].primary?.remainingPercent == 68, "Used percent converted to remaining")
        expect(snapshot.buckets[0].primary?.label == "Weekly", "Actual duration determines label")
        expect(snapshot.buckets[0].secondary == nil, "Null secondary remains unavailable")
        expect(snapshot.buckets[1].primary?.remainingPercent == 0, "Remaining clamps at zero")
        expect(snapshot.ordinaryUsageAllowed == false, "Backend permission must not be inferred from positive percentages")
        expect(snapshot.availableResets == 1, "Reset count decoded, never consumed")
        expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 123), "Fetch timestamp retained")

        let fallback = try decode(#"{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":-3},"secondary":{}},"rateLimitsByLimitId":{}}"#)
        expect(fallback.buckets.first?.id == "legacy", "Empty map uses legacy view")
        expect(fallback.buckets.first?.primary?.remainingPercent == 100, "Remaining clamps at 100")
        expect(fallback.buckets.first?.secondary?.remainingPercent == nil, "Missing value is unknown")
        expect(fallback.availableResets == nil && fallback.ordinaryUsageAllowed == nil, "Missing fields are unknown")

        let unknown = try decode(#"{"rateLimits":null,"rateLimitsByLimitId":null,"rateLimitResetCredits":null}"#)
        expect(unknown.buckets.isEmpty, "No usage is not interpreted as unused quota")
        let fractional = UsageWindow(usedPercent: 12.5, windowDurationMins: 300, resetsAt: nil)
        expect(fractional.remainingPercent == 87.5 && fractional.label == "5-hour", "Fractional values are preserved")
        expect(UsageWindow(usedPercent: .nan, windowDurationMins: nil, resetsAt: nil).remainingPercent == nil, "Nonfinite value is unknown")

    }

    static func testTransport() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("usage-provider-test-\(UUID().uuidString).pid")
        setenv("CODEX_USAGE_TEST_PID", pidFile.path, 1)
        defer {
            unsetenv("CODEX_USAGE_TEST_MODE")
            unsetenv("CODEX_USAGE_TEST_PID")
            try? FileManager.default.removeItem(at: pidFile)
        }
        for mode in ["success", "signin", "invalid", "exit", "timeout"] {
            setenv("CODEX_USAGE_TEST_MODE", mode, 1)
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let snapshot = try UsageProvider(timeout: mode == "timeout" ? 0.3 : 2,
                                                 executableURL: executable).fetch()
                expect(mode == "success", "Unexpected success in \(mode)")
                expect(snapshot.buckets.first?.primary?.remainingPercent == 68, "Framed response decoded")
            } catch let error as UsageProviderError {
                let expected: [String: UsageProviderError] = ["signin": .signInRequired, "invalid": .invalidResponse,
                                                             "exit": .connectionClosed, "timeout": .timedOut]
                expect(error == expected[mode], "Unexpected error in \(mode): \(error)")
                expect(!error.localizedDescription.contains("PRIVATE"), "Raw diagnostics must not leak")
            }
            expect(ProcessInfo.processInfo.systemUptime - started < 3, "Timeout and cleanup bounded")
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
            expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "Child process cleaned up in \(mode)")
        }
    }

    static func runFakeServer() {
        let environment = ProcessInfo.processInfo.environment
        try? String(getpid()).write(toFile: environment["CODEX_USAGE_TEST_PID"]!, atomically: true, encoding: .utf8)
        let mode = environment["CODEX_USAGE_TEST_MODE"]!
        if mode == "timeout" {
            signal(SIGTERM, SIG_IGN)
            Thread.sleep(forTimeInterval: 60)
            return
        }
        if mode == "exit" { return }
        guard readMethod() == "initialize" else { exit(10) }
        write(#"{"id":1,"result":{}}"# + "\n")
        guard readMethod() == "initialized" else { exit(11) }
        guard readMethod() == "account/rateLimits/read" else { exit(12) }
        if mode == "signin" {
            write(#"{"id":2,"error":{"code":-32600,"message":"not logged in PRIVATE/account/details"}}"# + "\n")
        } else if mode == "invalid" {
            write("not-json PRIVATE\n")
        } else {
            write(#"{"method":"account/rateLimits/updated","params":{}}"# + "\n")
            // Deliberately split the line across separate writes.
            write(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":32,"windowDurationMins":10080}}"#)
            Thread.sleep(forTimeInterval: 0.02)
            write("}}\n")
        }
        // Wait for EOF. Successful and failed refreshes must close the pipe.
        while readLine() != nil {}
    }

    static func write(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }

    static func readMethod() -> String? {
        guard let line = readLine(),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return object["method"] as? String
    }
}
