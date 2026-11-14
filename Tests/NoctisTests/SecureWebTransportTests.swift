// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Security
import Testing
import os
@testable import Noctis

#if os(macOS)
@Suite("Pinned public HTTPS transport", .serialized)
struct SecureWebTransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_PUBLIC_WEB_SMOKE"] == "1"))
    func publicPageSmoke() async throws {
        let url = "https://www.swift.org/documentation/"
        let web = WebToolDispatcher(searchService: EmptyPublicSearch(), pasgeService: HTTPWebPageService())
        let dispatcher = NoctisToolDispatcher(registry: NoctisToolRegistry(), web: web,
                                             userPrompt: "Lis cette page : " + url)
        let call = ToolCall(function: .init(name: "web_open", arguments: ["url": .string(url)]))
        let output = try await dispatcher.execute(call)
        let page = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(page["status"] as? String == "retrieved")
        #expect(page["url"] as? String == url)
        #expect(!(page["title"] as? String ?? "").isEmpty)
        #expect(!(page["content"] as? String ?? "").isEmpty)
    }

    @Test(arguments: ["127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254",
                      "0.0.0.0", "224.0.0.1", "100.64.0.1", "198.18.0.1", "192.0.2.1", "::1", "fc00::1",
                      "fe80::1", "ff02::1", "::ffff:127.0.0.1", "2001:db8::1", "fd00:ec2::254", "64:ff9b::7f00:1"])
    func rejectsEveryUnsafeDNSCandidate(_ numericIP: String) throws {
        let url = try #require(URL(string: "https://www.swift.org"))
        let publicIP = try SocketAddress(ipAddress: "1.1.1.1", port: 443)
        let unsafe = try SocketAddress(ipAddress: numericIP, port: 443)
        for addresses in [[unsafe], [publicIP, unsafe], [unsafe, publicIP]] {
            #expect(throws: WebPageError.invalidURL) { try PublicWebDestination(url: url, addresses: addresses) }
        }
    }

    @Test(arguments: ["1.1.1.1", "2606:4700:4700::1111"])
    func acceptsPublicDNSAddresses(_ numericIP: String) throws {
        let url = try #require(URL(string: "https://www.swift.org"))
        let address = try SocketAddress(ipAddress: numericIP, port: 443)
        #expect(try PublicWebDestination(url: url, addresses: [address]).address == address)
    }

    @Test func scopedPublicAddressIsRejected() throws {
        let url = try #require(URL(string: "https://www.swift.org"))
        let address = try SocketAddress(ipAddress: "2606:4700:4700::1111%1", port: 443)
        #expect(throws: WebPageError.invalidURL) { try PublicWebDestination(url: url, addresses: [address]) }
    }

    @Test func numericSnapshotSurvivesChangedDNS() throws {
        let url = try #require(URL(string: "https://www.swift.org"))
        var addresses = [try SocketAddress(ipAddress: "1.1.1.1", port: 443)]
        let pinned = try PublicWebDestination(url: url, addresses: addresses)
        addresses[0] = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        #expect(pinned.address.ipAddress == "1.1.1.1")
        #expect(throws: WebPageError.invalidURL) { try PublicWebDestination(url: url, addresses: addresses) }
        #expect(throws: WebPageError.invalidURL) { try PublicWebDestination(url: url, addresses: []) }
        let wrongPort = try SocketAddress(ipAddress: "1.1.1.1", port: 8443)
        #expect(throws: WebPageError.invalidURL) { try PublicWebDestination(url: url, addresses: [wrongPort]) }
    }

    @Test func privateDNSIsBlockedBeforeConnecting() async throws {
        let resolver = FixtureResolver(addresses: [try SocketAddress(ipAddress: "127.0.0.1", port: 443)])
        let transport = SecureWebTransport(resolver: resolver)
        await #expect(throws: WebPageError.invalidURL) {
            try await transport.get(#require(URL(string: "https://www.swift.org")))
        }
        #expect(resolver.count == 1)
    }

    @Test func stalledDNSHonorsCancellationAndGlobalDeadline() async throws {
        let resolver = FixtureResolver(addresses: nil)
        let transport = SecureWebTransport(resolver: resolver, client: PinnedHTTPClient(
            limits: try HTTPResponseLimits(requestTimeout: 1, resourceTimeout: 0.1)))
        let url = try #require(URL(string: "https://www.swift.org"))
        await #expect(throws: WebPageError.timedOut) { try await transport.get(url) }
        resolver.complete()
        let (started, ready) = AsyncStream<Void>.makeStream()
        let cancellationResolver = FixtureResolver(addresses: nil, onResolve: { ready.yield(()); ready.finish() })
        let cancellable = SecureWebTransport(resolver: cancellationResolver, client: PinnedHTTPClient(
            limits: try HTTPResponseLimits(requestTimeout: 10, resourceTimeout: 10)))
        let task = Task { try await cancellable.get(url) }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        cancellationResolver.complete()
    }

    @Test func concurrentRequestsAreBounded() async throws {
        let resolver = FixtureResolver(addresses: nil)
        let transport = SecureWebTransport(resolver: resolver)
        let url = try #require(URL(string: "https://www.swift.org"))
        let first = Task { try await transport.get(url) }
        let second = Task { try await transport.get(url) }
        for _ in 0..<100 where resolver.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await #expect(throws: WebPageError.requestLimit) { try await transport.get(url) }
        first.cancel()
        second.cancel()
        _ = await first.result
        _ = await second.result
        resolver.complete()
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func realTLSAndHTTPWithControlledTrust(_ bindHost: String) async throws {
        let fixture = try HTTPSFixture()
        let address = try await fixture.start(host: bindHost)
        do {
            let url = try #require(URL(string: "https://www.swift.org/article?q=bonjour"))
            let (data, response) = try await fetch(url, address: address, anchors: [fixture.material.root])
            #expect(response.url == url)
            #expect(String(data: data, encoding: .utf8)?.contains("article contrôlé") == true)
            #expect(response.value(forHTTPHeaderField: "Set-Cookie") == nil)
            #expect(fixture.requests == ["/article?q=bonjour"])
            #expect(fixture.hosts == ["www.swift.org"])
            #expect(fixture.serverNames == ["www.swift.org"])
        } catch { try? await fixture.stop(); throw error }
        try await fixture.stop()
    }

    @Test func invalidCertificateAndWrongHostnameFail() async throws {
        let fixture = try HTTPSFixture()
        let address = try await fixture.start()
        do {
            let url = try #require(URL(string: "https://www.swift.org/article"))
            await #expect(throws: (any Error).self) { try await fetch(url, address: address, anchors: []) }
            let wrong = try #require(URL(string: "https://www.apple.com/article"))
            await #expect(throws: (any Error).self) {
                try await fetch(wrong, address: address, anchors: [fixture.material.root])
            }
            #expect(fixture.requests.isEmpty)
            let trust = try PublicWebTLS(anchors: [fixture.material.root]).makeTrust(
                certificates: [fixture.material.leaf], hostname: "www.swift.org")
            var allowed = DarwinBoolean(true)
            #expect(SecTrustGetNetworkFetchAllowed(trust, &allowed) == errSecSuccess)
            #expect(!allowed.boolValue)
        } catch { try? await fixture.stop(); throw error }
        try await fixture.stop()
    }

    @Test(arguments: ["/redirect-private", "/redirect-http", "/large", "/chunked-large", "/gzip", "/binary",
                      "/headers", "/partial", "/malformed"])
    func hostileResponsesAreRejected(_ path: String) async throws {
        let fixture = try HTTPSFixture()
        let address = try await fixture.start()
        do {
            let url = try #require(URL(string: "https://www.swift.org" + path))
            await #expect(throws: WebPageError.self) {
                try await fetch(url, address: address, anchors: [fixture.material.root])
            }
            #expect(fixture.requests == [path])
        } catch { try? await fixture.stop(); throw error }
        try await fixture.stop()
    }

    @Test func receiveTimeoutAndCancellationCloseTheSocket() async throws {
        let fixture = try HTTPSFixture()
        let address = try await fixture.start()
        do {
            let url = try #require(URL(string: "https://www.swift.org/slow"))
            let limits = try HTTPResponseLimits(requestTimeout: 0.15, resourceTimeout: 1)
            await #expect(throws: WebPageError.timedOut) {
                try await fetch(url, address: address, anchors: [fixture.material.root], limits: limits)
            }
            let task = Task { try await fetch(url, address: address, anchors: [fixture.material.root]) }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } catch { try? await fixture.stop(); throw error }
        try await fixture.stop()
    }

    private func fetch(_ url: URL, address: SocketAddress, anchors: [Data],
                       limits: HTTPResponseLimits? = nil) async throws -> (Data, HTTPURLResponse) {
        let operation = PublicWebOperation(eventLoop: SecureWebTransport.group.next())
        let client = PinnedHTTPClient(limits: limits, tls: PublicWebTLS(anchors: anchors))
        return try await withTaskCancellationHandler {
            client.start(url: url, address: address, operation: operation)
            return try await operation.promise.futureResult.get()
        } onCancel: { operation.finish(.failure(CancellationError())) }
    }
}

private struct EmptyPublicSearch: WebSearchService {
    func search(query: String) async throws -> [SearchResult] { [] }
}

private final class FixtureResolver: PublicWebResolving, Sendable {
    private struct State { var calls = 0; var promises: [EventLoopPromise<[SocketAddress]>] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let addresses: [SocketAddress]?
    private let onResolve: @Sendable () -> Void
    init(addresses: [SocketAddress]?, onResolve: @escaping @Sendable () -> Void = {}) {
        self.addresses = addresses
        self.onResolve = onResolve
    }
    var count: Int { state.withLock { $0.calls } }
    func resolve(host: String, on eventLoop: any EventLoop) -> EventLoopFuture<[SocketAddress]> {
        let promise = eventLoop.makePromise(of: [SocketAddress].self)
        state.withLock { $0.calls += 1; if addresses == nil { $0.promises.append(promise) } }
        if let addresses { promise.succeed(addresses) }
        onResolve()
        return promise.futureResult
    }
    func complete() {
        let promises = state.withLock { state in
            let pending = state.promises
            state.promises = []
            return pending
        }
        for promise in promises { promise.fail(WebPageError.transportFailure) }
    }
}

private struct HTTPSMaterial: Sendable {
    static let shared: Result<HTTPSMaterial, any Error> = Result { try HTTPSMaterial() }
    let certificate: NIOSSLCertificate
    let key: NIOSSLPrivateKey
    let root: Data
    let leaf: Data

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func openssl(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WebPageError.invalidConfiguration }
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                     "-subj", "/CN=Noctis Test Root", "-keyout", "root.key", "-out", "root.pem"])
        try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=www.swift.org",
                     "-keyout", "server.key", "-out", "server.csr"])
        let extensions = """
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            subjectAltName=DNS:www.swift.org
            """
        try extensions.write(to: directory.appendingPathComponent("leaf.conf"), atomically: true, encoding: .utf8)
        try openssl(["x509", "-req", "-in", "server.csr", "-CA", "root.pem", "-CAkey", "root.key",
                     "-CAcreateserial", "-days", "1", "-extfile", "leaf.conf", "-out", "server.pem"])
        certificate = try #require(NIOSSLCertificate.fromPEMFile(
            directory.appendingPathComponent("server.pem").path).first)
        key = try NIOSSLPrivateKey(file: directory.appendingPathComponent("server.key").path, format: .pem)
        root = Data(try #require(NIOSSLCertificate.fromPEMFile(
            directory.appendingPathComponent("root.pem").path).first).toDERBytes())
        leaf = Data(try certificate.toDERBytes())
    }
}

private final class HTTPSFixture: Sendable {
    let material: HTTPSMaterial
    private struct State {
        var requests: [String] = []
        var hosts: [String] = []
        var serverNames: [String] = []
        var channels: [any Channel] = []
        var server: (any Channel)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init() throws { material = try HTTPSMaterial.shared.get() }
    var requests: [String] { state.withLock { $0.requests } }
    var hosts: [String] { state.withLock { $0.hosts } }
    var serverNames: [String] { state.withLock { $0.serverNames } }

    func start(host: String = "127.0.0.1") async throws -> SocketAddress {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(material.certificate)], privateKey: .privateKey(material.key))
        configuration.sslContextCallback = { [self] values, promise in
            state.withLock { $0.serverNames.append(values.serverHostname ?? "") }
            promise.succeed(.noChanges)
        }
        let context = try NIOSSLContext(configuration: configuration)
        let server = try await ServerBootstrap(group: SecureWebTransport.group)
            .childChannelInitializer { [self] channel in
                state.withLock { $0.channels.append(channel) }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(HTTPSFixtureHandler { path, host in
                        self.state.withLock { $0.requests.append(path); $0.hosts.append(host) }
                        return Self.response(path)
                    })
                }
            }.bind(host: host, port: 0).get()
        state.withLock { $0.server = server }
        return try #require(server.localAddress)
    }

    func stop() async throws {
        let channels = state.withLock { state in
            let channels = state.channels + (state.server.map { [$0] } ?? [])
            state.channels = []
            state.server = nil
            return channels
        }
        for channel in channels { try? await channel.close().get() }
    }

    private static func response(_ path: String) -> String? {
        switch path {
        case "/slow": return nil
        case "/redirect-private", "/redirect-http":
            let target = path == "/redirect-private" ? "https://127.0.0.1/" : "http://www.swift.org/"
            return "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\n\r\n"
        case "/large": return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2097153\r\n\r\n"
        case "/chunked-large":
            let body = String(repeating: "a", count: 2_097_153)
            return "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n200001\r\n" + body + "\r\n0\r\n\r\n"
        case "/gzip":
            return "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html\r\n"
                + "Content-Encoding: gzip\r\n"
                + "Content-Length: 0\r\n\r\n"
        case "/binary": return "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: 0\r\n\r\n"
        case "/headers": return "HTTP/1.1 200 OK\r\nX-Large: " + String(repeating: "a", count: 40_000) + "\r\n\r\n"
        case "/partial": return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1000\r\n\r\npartial"
        case "/malformed": return "definitely not HTTP\r\n\r\n"
        default:
            let body = "<html><title>Test</title><article>Un article contrôlé.</article></html>"
            return "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Set-Cookie: secret=value\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        }
    }
}

private final class HTTPSFixtureHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let buffer = OSAllocatedUnfairLock(initialState: "")
    let response: @Sendable (String, String) -> String?
    init(response: @escaping @Sendable (String, String) -> String?) { self.response = response }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = String(buffer: unwrapInboundIn(data))
        let request = buffer.withLock { text -> String? in
            text += value
            guard text.contains("\r\n\r\n") else { return nil }
            return text
        }
        guard let request else { return }
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let host = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("host:") })?
            .dropFirst(5).trimmingCharacters(in: .whitespaces) ?? ""
        if let response = response(path, host) {
            var output = context.channel.allocator.buffer(capacity: response.utf8.count)
            output.writeString(response)
            context.writeAndFlush(NIOAny(output), promise: nil)
            context.close(promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

#endif
