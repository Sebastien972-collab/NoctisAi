// Created by Sébastien DAGUIN

import Foundation
import Testing
@testable import NoctisCLI

struct FixtureArchiveRunner: UpdateCommandRunning {
    func run(_ executable: URL, _ arguments: [String], directory: URL?) async throws -> String {
        if executable.path == "/test/gh" { return "Mocked publisher identity accepted" }
        return try await UpdateCommandRunner().run(executable, arguments, directory: directory)
    }
}

actor FixtureDevelopmentRunner: UpdateCommandRunning {
    let products: URL
    var calls: [String] = []
    init(products: URL) { self.products = products }
    func run(_ executable: URL, _ arguments: [String], directory: URL?) async throws -> String {
        calls.append(([executable.path] + arguments).joined(separator: " "))
        if arguments == ["swift", "--version"] { return "Apple Swift version 6.4.1 (test fixture)" }
        if arguments.contains("rev-parse") { return String(repeating: "a", count: 40) }
        if arguments.contains("--show-bin-path") { return products.path }
        if arguments == ["--version"] {
            return CLIBuildIdentity(version: "0.2.0-dev", channel: "main",
                                    commit: String(repeating: "a", count: 40)).display
        }
        return "OK"
    }
}

actor FixtureUpdateTransport: UpdateTransport {
    var responses: [Data]
    let interrupted: Bool
    var urls: [URL] = []
    init(responses: [Data], interrupted: Bool = false) {
        self.responses = responses
        self.interrupted = interrupted
    }
    func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws {
        urls.append(url)
        if interrupted {
            try Data("partial".utf8).write(to: destination)
            throw URLError(.networkConnectionLost)
        }
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        let data = responses.removeFirst()
        #expect(data.count <= maximumSize)
        try data.write(to: destination)
    }
}

actor FixtureUpdateRunner: UpdateCommandRunning {
    let failAttestation: Bool
    let failActivation: Bool
    var calls: [String] = []
    init(failAttestation: Bool = false, failActivation: Bool = false) {
        self.failAttestation = failAttestation
        self.failActivation = failActivation
    }
    func run(_ executable: URL, _ arguments: [String], directory: URL?) async throws -> String {
        calls.append(([executable.path] + arguments).joined(separator: " "))
        if arguments.first == "attestation", failAttestation {
            throw UpdateFailure("Integrity verification failed. Nothing was installed.")
        }
        if executable.path.hasSuffix("/bin/noctis"), failActivation {
            throw UpdateFailure("The application executable is missing.")
        }
        return arguments == ["--version"] ? "Noctis 1.0.0 (stable)\n" : "OK"
    }
}

struct UpdateFixture {
    let base: URL
    var prefix: URL { base.appendingPathComponent("prefix") }
    var root: URL { prefix.appendingPathComponent("share/noctis") }
    var old: URL { root.appendingPathComponent("versions/build-old") }
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "noctis-test-\(UUID())")
        for path in [old, prefix.appendingPathComponent("bin")] {
            try FileManager.default.createDirectory(
                at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("old binary".utf8).write(to: old.appendingPathComponent("NoctisCLI"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: old.appendingPathComponent("NoctisCLI").path)
        try ManagedCLIInstallation.seal(old)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("current").path,
            withDestinationPath: "versions/build-old")
        try FileManager.default.createSymbolicLink(
            atPath: prefix.appendingPathComponent("bin/noctis").path,
            withDestinationPath: root.appendingPathComponent("current/NoctisCLI").path)
    }
    func payload() throws -> URL {
        let path = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try Data("new binary".utf8).write(to: path.appendingPathComponent("NoctisCLI"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path.appendingPathComponent("NoctisCLI").path)
        return path
    }
    func installation(_ runner: any UpdateCommandRunning) throws -> ManagedCLIInstallation {
        try ManagedCLIInstallation(
            prefix: prefix, executable: prefix.appendingPathComponent("bin/noctis").resolvingSymlinksInPath(),
            runner: runner)
    }
    func active() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("current").path)
    }
    func previous() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("previous").path)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
