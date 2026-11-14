//
//  EmbeddedSearXNGServiceTests.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 05/11/2026.
//

#if os(macOS)
import Foundation
import Darwin
import Testing
@testable import Noctis

struct EmbeddedSearXNGServiceTests {
    private let python = URL(fileURLWithPath: "/usr/bin/python3")

    // Exercise the production bootstrap with a stdlib WSGI fixture, without engines/network/MLX.
    private var fixture: String {
        #"""
        import json, os, sys, time, types
        from wsgiref.simple_server import make_server as std_server, WSGIRequestHandler
        from urllib.parse import parse_qs
        fixture_token = os.environ["NOCTIS_TOKEN"]
        def app(environ, start_response):
            query = parse_qs(environ.get("QUERY_STRING", "")).get("q", [""])[0]
            if query == "crash":
                os._exit(7)
            if query == "slow":
                time.sleep(3)
            start_response("200 OK", [("Content-Type", "application/json")])
            return [json.dumps({"results": [{"title": str(os.getpid()),
                "url": "https://www.swift.org", "content": fixture_token if query == "token" else environ["SERVER_PORT"]}]}).encode()]
        def make_server(host, port, application, **kwargs):
            return std_server(host, port, application)
        webapp = types.ModuleType("searx.webapp")
        webapp.app = app
        serving = types.ModuleType("werkzeug.serving")
        serving.make_server = make_server
        serving.WSGIRequestHandler = WSGIRequestHandler
        sys.modules["searx"] = types.ModuleType("searx")
        sys.modules["searx.webapp"] = webapp
        sys.modules["werkzeug"] = types.ModuleType("werkzeug")
        sys.modules["werkzeug.serving"] = serving
        """# + "\n" + EmbeddedSearXNGService.bootstrap
    }

    private func service(idle: Duration = .seconds(10), script: String? = nil,
                         startup: Duration = .seconds(5)) throws -> EmbeddedSearXNGService {
        try EmbeddedSearXNGService(pythonExecutable: python, idleTimeout: idle,
                                  startupTimeout: startup, launchScript: script ?? fixture)
    }

    private func waitForExit(_ pid: Int32) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(pid, 0) != 0)
    }

    @Test func lazyValidationAndMissingRuntime() async throws {
        let search = try EmbeddedSearXNGService(pythonExecutable: URL(fileURLWithPath: "/missing/python"))
        await #expect(throws: WebToolError.self) { try await search.search(query: " ") }
        await #expect(throws: EmbeddedSearXNGError.runtimeUnavailable) { try await search.search(query: "Swift") }
        await search.shutdown()
    }

    @Test func reuseAuthenticationShutdownAndRestart() async throws {
        let search = try service()
        do {
            let first = try #require(try await search.search(query: "Swift").first)
            let pid = try #require(Int32(first.title))
            let next = try #require(try await search.search(query: "Swift again").first)
            #expect(first.title == next.title)
            let port = try #require(first.content)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/healthz"))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
            let tokenResult = try #require(try await search.search(query: "token").first)
            let token = try #require(tokenResult.content)
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "X-Noctis-Token")
            request.setValue("https://example.com", forHTTPHeaderField: "Origin")
            let (_, crossOrigin) = try await session.data(for: request)
            #expect((crossOrigin as? HTTPURLResponse)?.statusCode == 403)
            request.setValue(nil, forHTTPHeaderField: "Origin")
            request.url = url.deletingLastPathComponent().appendingPathComponent("config")
            let (_, restricted) = try await session.data(for: request)
            #expect((restricted as? HTTPURLResponse)?.statusCode == 404)
            await search.shutdown()
            try await waitForExit(pid)
            let restarted = try #require(try await search.search(query: "restart").first)
            #expect(restarted.title != first.title)
        } catch {
            await search.shutdown()
            throw error
        }
        await search.shutdown()
    }

    @Test func idleStop() async throws {
        let search = try service(idle: .milliseconds(100))
        let result: SearchResult
        do { result = try #require(try await search.search(query: "Swift").first) }
        catch { await search.shutdown(); throw error }
        let pid = try #require(Int32(result.title))
        try await waitForExit(pid)
        await search.shutdown()
    }

    @Test func startupExitAndTimeout() async throws {
        let exited = try service(script: "import sys; sys.exit(9)")
        await #expect(throws: EmbeddedSearXNGError.startupFailed(9)) { try await exited.search(query: "Swift") }
        await exited.shutdown()
        let timeout = try service(script: "import time; time.sleep(30)", startup: .milliseconds(100))
        await #expect(throws: EmbeddedSearXNGError.startupTimedOut) { try await timeout.search(query: "Swift") }
        await timeout.shutdown()
    }

    @Test func startupCancellation() async throws {
        let search = try service(script: "import time; time.sleep(30)")
        let task = Task { try await search.search(query: "Swift") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await search.shutdown()
    }

    @Test func shutdownCancelsActiveRequest() async throws {
        let search = try service()
        let first = try #require(try await search.search(query: "Swift").first)
        let pid = try #require(Int32(first.title))
        let slow = Task { try await search.search(query: "slow") }
        try await Task.sleep(for: .milliseconds(100))
        await search.shutdown()
        await #expect(throws: CancellationError.self) { try await slow.value }
        try await waitForExit(pid)
    }

    @Test(.timeLimit(.minutes(1))) func lifetimePipeStopsOrphan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-I", "-B", "-u", "-c", fixture]
        child.environment = ["NOCTIS_TOKEN": "fixture", "NOCTIS_READY_PATH": root.appendingPathComponent("ready").path]
        let pipe = Pipe()
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let (exits, exited) = AsyncStream<Int32>.makeStream()
        child.terminationHandler = { process in
            exited.yield(process.terminationStatus)
            exited.finish()
        }
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.close()
        var status: Int32?
        for await exitStatus in exits { status = exitStatus; break }
        #expect(status == 0)
    }

    @Test func cancellationConcurrencyAndCrashRecovery() async throws {
        let search = try service(idle: .milliseconds(100))
        do {
            let first = try #require(try await search.search(query: "Swift").first)
            let pid = try #require(Int32(first.title))
            let slow = Task { try await search.search(query: "slow") }
            try await Task.sleep(for: .milliseconds(250))
            // Idle expiry must not interrupt an active request.
            #expect(kill(pid, 0) == 0)
            await #expect(throws: EmbeddedSearXNGError.busy) { try await search.search(query: "overlap") }
            slow.cancel()
            await #expect(throws: CancellationError.self) { try await slow.value }
            try await waitForExit(pid)
            await #expect(throws: WebPageError.self) { try await search.search(query: "crash") }
            let recovered = try #require(try await search.search(query: "recovery").first)
            #expect(recovered.title != first.title)
        } catch { await search.shutdown(); throw error }
        await search.shutdown()
    }

    @Test func configurationBounds() throws {
        #expect(throws: EmbeddedSearXNGError.invalidConfiguration) {
            try EmbeddedSearXNGService(pythonExecutable: python, idleTimeout: .zero)
        }
        #expect(throws: EmbeddedSearXNGError.invalidConfiguration) {
            try EmbeddedSearXNGService(pythonExecutable: python, startupTimeout: .seconds(121))
        }
        #expect(try EmbeddedSearXNGService.bundled(in: Bundle(for: WebFixtureProtocol.self)) == nil)
    }

    @Test func installedRuntimeDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try EmbeddedSearXNGService.installed(in: root) == nil)
        let python = root.appendingPathComponent("Noctis/SearXNG/venv/bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# Created by Sébastien DAGUIN\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: python.path)
        #expect(throws: EmbeddedSearXNGError.runtimeUnavailable) {
            try EmbeddedSearXNGService.installed(in: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        #expect(try EmbeddedSearXNGService.installed(in: root) != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCTIS_TEST_SEARXNG_PYTHON"] != nil))
    func realRuntimeSmoke() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NOCTIS_TEST_SEARXNG_PYTHON"])
        let search = try EmbeddedSearXNGService(pythonExecutable: URL(fileURLWithPath: path))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let results = try await search.search(query: "Swift programming language")
            let cold = start.duration(to: clock.now)
            let warmStart = clock.now
            _ = try await search.search(query: "Swift programming language")
            print("SearXNG cold search: \(cold); warm search: \(warmStart.duration(to: clock.now)); results: \(results.count)")
        } catch { await search.shutdown(); throw error }
        await search.shutdown()
    }
}
#endif
