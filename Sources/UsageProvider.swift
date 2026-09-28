import Foundation
import Darwin

enum UsageProviderError: LocalizedError, Equatable {
    case codexNotFound
    case couldNotStart
    case timedOut
    case connectionClosed
    case invalidResponse
    case signInRequired
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex could not be found. Install the Codex CLI or the Codex desktop app, then refresh."
        case .couldNotStart:
            return "Codex could not start. Open Codex once, then refresh."
        case .timedOut:
            return "Usage refresh timed out. Check your connection and try again."
        case .connectionClosed:
            return "Codex closed the usage connection. Open Codex and sign in, then refresh."
        case .invalidResponse:
            return "Codex returned an unsupported usage response. Update Codex and try again."
        case .signInRequired:
            return "Sign into Codex with your ChatGPT account, then refresh."
        case .usageUnavailable:
            return "Usage is unavailable right now. Check your Codex sign-in and connection, then refresh."
        }
    }
}

/// Reads account limits through Codex's existing login. No model turns are
/// started, and no credit/reset/purchase method is called.
final class UsageProvider {
    private let timeout: TimeInterval
    private let executableOverride: URL?

    init(timeout: TimeInterval = 25, executableURL: URL? = nil) {
        self.timeout = max(0.1, timeout)
        self.executableOverride = executableURL
    }

    func fetch() throws -> UsageSnapshot {
        guard let executable = executableOverride ?? CodexExecutableLocator.locate() else {
            throw UsageProviderError.codexNotFound
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        // A neutral working directory avoids activating the repository the
        // widget happened to be launched from.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // Broken pipes should become a controlled refresh failure, never kill
        // the menu bar process.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            try process.run()
        } catch {
            close(input: input, output: output)
            throw UsageProviderError.couldNotStart
        }
        // The child has its own descriptor copies. Closing the unused local
        // ends makes EOF observable even if the child fails before responding.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            stop(process)
            try? output.fileHandleForReading.close()
        }

        var pending = Data()
        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "codex_usage_menubar", "title": "Codex Usage", "version": "1.0.0"],
                "capabilities": ["experimentalApi": false]
            ]
        ], to: input.fileHandleForWriting)
        _ = try response(id: 1, from: output.fileHandleForReading, pending: &pending, deadline: deadline)
        try send(["method": "initialized"], to: input.fileHandleForWriting)
        try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()],
                 to: input.fileHandleForWriting)
        let result = try response(id: 2, from: output.fileHandleForReading,
                                  pending: &pending, deadline: deadline)
        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            return try UsageResponseDecoder.decode(data)
        } catch {
            throw UsageProviderError.invalidResponse
        }
    }

    private func send(_ message: [String: Any], to handle: FileHandle) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            throw UsageProviderError.connectionClosed
        }
    }

    private func response(id: Int, from handle: FileHandle, pending: inout Data,
                          deadline: TimeInterval) throws -> [String: Any] {
        while true {
            let line = try nextLine(from: handle, pending: &pending, deadline: deadline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageProviderError.invalidResponse
            }
            // Ignore notifications and responses to other request IDs.
            guard (object["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = object["error"] as? [String: Any] {
                // Never expose arbitrary server messages: they may contain
                // account details or request diagnostics. Classify locally.
                let message = (error["message"] as? String ?? "").lowercased()
                if message.contains("not logged in") || message.contains("not signed in") ||
                    message.contains("unauthorized") || message.contains("authentication") ||
                    message.contains("chatgpt auth") || message.contains("api key") {
                    throw UsageProviderError.signInRequired
                }
                throw UsageProviderError.usageUnavailable
            }
            guard let result = object["result"] as? [String: Any] else {
                throw UsageProviderError.invalidResponse
            }
            return result
        }
    }

    private func nextLine(from handle: FileHandle, pending: inout Data,
                          deadline: TimeInterval) throws -> Data {
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw UsageProviderError.timedOut
            }
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if line.isEmpty { continue }
                return Data(line)
            }
            // Usage responses are small. Bound memory if a bad server sends
            // an unframed stream.
            guard pending.count < 1_048_576 else { throw UsageProviderError.invalidResponse }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(1_000, remaining * 1_000)))
            let readiness = Darwin.poll(&descriptor, 1, milliseconds)
            if readiness == 0 { continue }
            if readiness < 0 {
                if errno == EINTR { continue }
                throw UsageProviderError.connectionClosed
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw UsageProviderError.connectionClosed
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count == 0 { throw UsageProviderError.connectionClosed }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw UsageProviderError.connectionClosed
            }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }

    private func stop(_ process: Process) {
        // Give normal EOF shutdown a short chance, then bound cleanup even for
        // a stalled app-server. The locator uses a native executable directly.
        var deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func close(input: Pipe, output: Pipe) {
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in directories + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path] {
            candidates.append(URL(fileURLWithPath: directory).appendingPathComponent("codex"))
        }
        // Login-shell PATH is typically absent in apps launched by Finder.
        let nodeVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nodeVersions, includingPropertiesForKeys: nil) {
            for version in versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
                candidates.append(version.appendingPathComponent("bin/codex"))
            }
        }
        for appRoot in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for app in ["Codex.app", "ChatGPT.app"] {
                candidates.append(appRoot.appendingPathComponent("\(app)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
                candidates.append(appRoot.appendingPathComponent("\(app)/Contents/Resources/codex"))
            }
        }
        var visited = Set<String>()
        for candidate in candidates {
            let real = candidate.resolvingSymlinksInPath()
            guard visited.insert(real.path).inserted else { continue }
            if let native = nativeExecutable(for: real), fileManager.isExecutableFile(atPath: native.path) {
                return native
            }
        }
        return nil
    }

    private static func nativeExecutable(for executable: URL) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        if executable.pathExtension == "js" {
            #if arch(arm64)
            let package = "codex-darwin-arm64"
            let triple = "aarch64-apple-darwin"
            #else
            let package = "codex-darwin-x64"
            let triple = "x86_64-apple-darwin"
            #endif
            let root = executable.deletingLastPathComponent().deletingLastPathComponent()
            let roots = [root.appendingPathComponent("node_modules/@openai/\(package)"),
                         root.deletingLastPathComponent().appendingPathComponent(package), root]
            for packageRoot in roots {
                // Newer and older CLI package layouts.
                for tail in ["bin/codex", "codex/codex"] {
                    let native = packageRoot.appendingPathComponent("vendor/\(triple)/\(tail)")
                    if fileManager.isExecutableFile(atPath: native.path) { return native }
                }
            }
            return nil
        }
        // The desktop app's small shell launcher execs this sibling binary.
        let appNative = executable.deletingLastPathComponent().appendingPathComponent("../CodexCLI.app/Contents/MacOS/codex").standardizedFileURL
        if fileManager.isExecutableFile(atPath: appNative.path) { return appNative }
        return executable
    }
}
