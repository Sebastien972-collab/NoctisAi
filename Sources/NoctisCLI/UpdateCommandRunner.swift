import Foundation

protocol UpdateCommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], directory: URL?) async throws -> String
}

private final class UpdateChild: @unchecked Sendable {
    let process = Process()
    let lock = NSLock()
    var cancelled = false

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    func waitForExit() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    let code = process.terminationStatus
                    continuation.resume(returning: process.terminationReason == .exit ? code : -code)
                }
                do { try start() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

struct UpdateCommandRunner: UpdateCommandRunning {
    func run(_ executable: URL, _ arguments: [String], directory: URL? = nil) async throws -> String {
        let child = UpdateChild()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctis-process-\(UUID())")
        let created = FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600])
        guard created else {
            throw UpdateFailure("Cannot create a private temporary file.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        child.process.executableURL = executable
        child.process.arguments = arguments
        child.process.currentDirectoryURL = directory
        child.process.standardOutput = output
        child.process.standardError = output
        child.process.standardInput = FileHandle.nullDevice
        child.process.environment = Self.environment()
        let status = try await child.waitForExit()
        try Task.checkCancellation()
        if status != 0 {
            throw UpdateCommandFailure(command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                                       status: status, details: try Self.tail(of: temporary))
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 8 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else {
            throw UpdateFailure("Invalid command output (over 8 MiB or invalid UTF-8).")
        }
        return text
    }

    private static func environment() -> [String: String] {
        // Ignore Git rewrites/hooks and dynamic-loader overrides inherited from the caller.
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("GIT_") && !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("LD_")
        }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_HOST"] = "github.com"
        return environment
    }

    private static func tail(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        try file.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
        let bytes = try file.readToEnd() ?? Data()
        let text = bytes.split(separator: 10).suffix(20).compactMap { String(bytes: $0, encoding: .utf8) }
        return text.joined(separator: "\n")
    }
}

struct UpdateCommandFailure: LocalizedError {
    let command: String
    let status: Int32
    let details: String

    var errorDescription: String? {
        TerminalMarkdown.sanitized("\(command) (\(status))\n\(details)")
    }
}
