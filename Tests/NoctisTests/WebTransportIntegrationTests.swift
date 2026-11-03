import Foundation
import Network
import Synchronization
import Testing
@testable import Noctis

/// Binds only an ephemeral loopback port; never contacts an existing private service.
private final class ControlledHTTPServer: Sendable {
    let listener: NWListener
    private let connections = Mutex<[NWConnection]>([])
    private let paths = Mutex<[String]>([])
    private let queue = DispatchQueue(label: "Noctis.HTTPFixture")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<Void, any Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                default: return
                }
                let shouldResume = completed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldResume { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.withLock { $0.append(connection) }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)"))
    }

    func stop() {
        listener.cancel()
        connections.withLock { connections in
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    var receivedPaths: [String] { paths.withLock { $0 } }

    private func trickle(_ connection: NWConnection) {
        connection.send(content: Data("1\r\na\r\n".utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.trickle(connection)
            }
        })
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= 8_192 else { connection.cancel(); return }
            let text = String(decoding: request, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if complete { connection.cancel() }
                else { self.receive(connection, accumulated: request) }
                return
            }
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.paths.withLock { $0.append(path) }
            if path == "/slow" { return }
            if path == "/trickle" {
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n".utf8),
                                completion: .contentProcessed { [weak self] error in
                    if error == nil { self?.trickle(connection) }
                })
                return
            }
            let response: String
            if path == "/redirect" {
                response = "HTTP/1.1 302 Found\r\nLocation: /forbidden\r\nContent-Length: 0\r\n\r\n"
            } else if path == "/partial" {
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1000\r\nConnection: close\r\n\r\npartial"
            } else if path.hasPrefix("/search?") {
                let body = #"{"results":[{"title":"Fixture","url":"https://www.swift.org","content":"Controlled search"}]}"#
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            } else {
                let size = path == "/large" ? 2_097_153 : 32
                let body = String(repeating: "a", count: size)
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                    + String(size, radix: 16) + "\r\n" + body + "\r\n0\r\n\r\n"
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

struct WebTransportIntegrationTests {
    @Test func controlledLoopbackTransport() async throws {
        let server = try ControlledHTTPServer()
        defer { server.stop() }
        let base = try await server.start()
        let client = BoundedHTTPClient(limits: try HTTPResponseLimits(requestTimeout: 1, resourceTimeout: 2))

        let (small, _) = try await client.get(base.appendingPathComponent("chunked"), mimeTypes: ["text/html"])
        #expect(small.count == 32)
        await #expect(throws: WebPageError.responseTooLarge) {
            try await client.get(base.appendingPathComponent("large"), mimeTypes: ["text/html"])
        }
        await #expect(throws: WebPageError.redirectDenied) {
            try await client.get(base.appendingPathComponent("redirect"), mimeTypes: ["text/html"])
        }
        #expect(!server.receivedPaths.contains("/forbidden"))
        await #expect(throws: WebPageError.self) {
            try await client.get(base.appendingPathComponent("partial"), mimeTypes: ["text/html"])
        }
        await #expect(throws: WebPageError.timedOut) {
            try await client.get(base.appendingPathComponent("slow"), mimeTypes: ["text/html"])
        }
        let resourceLimited = BoundedHTTPClient(limits: try HTTPResponseLimits(requestTimeout: 5, resourceTimeout: 1))
        await #expect(throws: WebPageError.timedOut) {
            try await resourceLimited.get(base.appendingPathComponent("trickle"), mimeTypes: ["text/html"])
        }
        let cancelled = Task {
            try await client.get(base.appendingPathComponent("slow"), mimeTypes: ["text/html"])
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let results = try await SearXNGService(baseURL: base).search(query: "controlled fixture")
        #expect(results.first?.title == "Fixture")
    }
}
