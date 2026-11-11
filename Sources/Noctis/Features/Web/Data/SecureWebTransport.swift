// Created by Sébastien DAGUIN

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import os

/// Public egress only. The local SearXNG URLSession never participates in this path.
actor SecureWebTransport {
    static let shared = SecureWebTransport()
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let resolver: any PublicWebResolving
    private let client: PinnedHTTPClient
    private var active = 0

    init(resolver: any PublicWebResolving = PublicWebResolver(),
         client: PinnedHTTPClient = PinnedHTTPClient()) {
        self.resolver = resolver
        self.client = client
    }

    func get(_ rawURL: URL) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let url = try PublicWebURLPolicy.validate(rawURL.absoluteString)
        guard let hostname = url.host else { throw WebPageError.invalidURL }
        guard active < 2 else { throw WebPageError.requestLimit }
        active += 1
        defer { active -= 1 }
        let loop = Self.group.next()
        let operation = PublicWebOperation(eventLoop: loop)
        let deadline = loop.scheduleTask(in: .nanoseconds(Int64(client.limits.resourceTimeout * 1_000_000_000))) {
            operation.finish(.failure(WebPageError.timedOut))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            if !operation.isFinished {
                resolver.resolve(host: hostname, on: loop).whenComplete { [client] result in
                    guard !operation.isFinished else { return }
                    do {
                        let destination = try PublicWebDestination(url: url, addresses: result.get())
                        client.start(url: destination.url, address: destination.address, operation: operation)
                    } catch {
                        operation.finish(.failure(error as? WebPageError ?? .transportFailure))
                    }
                }
            }
            let result = try await operation.promise.futureResult.get()
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }
}

/// A single completion owns cancellation, the connecting socket and all response state.
final class PublicWebOperation: Sendable {
    private struct State {
        var channel: (any Channel)?
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let promise: EventLoopPromise<(Data, HTTPURLResponse)>

    init(eventLoop: any EventLoop) { promise = eventLoop.makePromise() }
    var isFinished: Bool { state.withLock { $0.finished } }

    func register(_ channel: any Channel) -> Bool {
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            state.channel = channel
            return true
        }
        if !accepted { channel.close(promise: nil) }
        return accepted
    }

    func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let completion = state.withLock { state -> (Bool, (any Channel)?) in
            guard !state.finished else { return (false, nil) }
            state.finished = true
            let channel = state.channel
            state.channel = nil
            return (true, channel)
        }
        guard completion.0 else { return }
        guard let channel = completion.1 else {
            promise.completeWith(result)
            return
        }
        channel.eventLoop.execute { [promise] in
            // Abort the socket below TLS: cancellation must not wait for a peer's close_notify.
            if let context = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLClientHandler.self) {
                context.close(promise: nil)
            } else {
                channel.close(promise: nil)
            }
            // Keep the concurrency slot until the underlying socket is actually closed.
            channel.closeFuture.whenComplete { _ in promise.completeWith(result) }
        }
    }
}

/// Numeric TCP endpoints only: no DNS, proxy discovery, redirects, retries or shared cookies.
struct PinnedHTTPClient: Sendable {
    private static let context: Result<NIOSSLContext, any Error> = Result {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .fullVerification
        configuration.applicationProtocols = ["http/1.1"]
        return try NIOSSLContext(configuration: configuration)
    }
    static var isAvailable: Bool { (try? context.get()) != nil }
    let limits: HTTPResponseLimits
    let tls: PublicWebTLS

    init(limits: HTTPResponseLimits? = nil, tls: PublicWebTLS = PublicWebTLS()) {
        if let limits {
            self.limits = limits
        } else {
            do { self.limits = try HTTPResponseLimits() } catch {
                preconditionFailure("Static HTTP limits are invalid.")
            }
        }
        self.tls = tls
    }

    func start(url: URL, address: SocketAddress, operation: PublicWebOperation) {
        let loop = operation.promise.futureResult.eventLoop
        let deadline = loop.scheduleTask(in: .nanoseconds(Int64(limits.requestTimeout * 1_000_000_000))) {
            operation.finish(.failure(WebPageError.timedOut))
        }
        operation.promise.futureResult.whenComplete { _ in deadline.cancel() }
        guard let hostname = url.host else {
            operation.finish(.failure(WebPageError.invalidURL))
            return
        }
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.nanoseconds(Int64(limits.requestTimeout * 1_000_000_000)))
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.recvAllocator,
                           value: AdaptiveRecvByteBufferAllocator(minimum: 4_096, initial: 16_384, maximum: 32_768))
            .channelInitializer { channel in
                configure(channel: channel, url: url, hostname: hostname, operation: operation)
            }
        // This overload takes an already-parsed sockaddr. It never resolves the original hostname.
        bootstrap.connect(to: address).whenComplete { result in
            do {
                let channel = try result.get()
                guard !operation.isFinished, channel.remoteAddress == address else {
                    operation.finish(.failure(WebPageError.transportFailure))
                    return
                }
                guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw WebPageError.invalidURL
                }
                let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
                let target = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
                let headers = HTTPHeaders([
                    ("Host", hostname), ("Accept", "text/html, application/xhtml+xml"),
                    ("Accept-Encoding", "identity"), ("Connection", "close"), ("User-Agent", "Noctis/1.0")
                ])
                let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target, headers: headers)
                channel.write(HTTPClientRequestPart.head(head), promise: nil)
                channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { _ in
                    operation.finish(.failure(WebPageError.transportFailure))
                }
            } catch {
                let failure: any Error = error is CancellationError
                    ? CancellationError() : WebPageError.transportFailure
                operation.finish(.failure(failure))
            }
        }
    }

    private func configure(channel: any Channel, url: URL, hostname: String,
                           operation: PublicWebOperation) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            guard operation.register(channel) else { throw CancellationError() }
            let ssl = try NIOSSLClientHandler(context: Self.context.get(), serverHostname: hostname,
                customVerificationCallback: { certificates, promise in
                    tls.verify(certificates, hostname: hostname, promise: promise)
                })
            var decoderLimits = NIOHTTPDecoderLimitConfiguration()
            decoderLimits.maxHeaderFieldSize = 8_192
            decoderLimits.maxHeaderListSize = 32_768
            decoderLimits.maxHeaderFieldCount = 100
            try channel.pipeline.syncOperations.addHandler(PublicWebWireLimit(operation: operation))
            try channel.pipeline.syncOperations.addHandler(ssl)
            try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder())
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder(
                leftOverBytesStrategy: .fireError, informationalResponseStrategy: .forward,
                limitConfiguration: decoderLimits)))
            try channel.pipeline.syncOperations.addHandler(PublicWebResponseHandler(
                url: url, maximumBytes: limits.maximumBytes, operation: operation))
        }
    }

}

/// Includes encrypted handshake/header overhead, before buffering inside TLS or the HTTP parser.
private final class PublicWebWireLimit: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let bytes = OSAllocatedUnfairLock(initialState: 0)
    let operation: PublicWebOperation
    init(operation: PublicWebOperation) { self.operation = operation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let count = unwrapInboundIn(data).readableBytes
        let allowed = bytes.withLock { total in
            guard count <= 3 * 1_024 * 1_024 - total else { return false }
            total += count
            return true
        }
        if allowed { context.fireChannelRead(data) } else { operation.finish(.failure(WebPageError.responseTooLarge)) }
    }
}

private final class PublicWebResponseHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPClientResponsePart
    private struct State {
        var response: HTTPURLResponse?
        var data = Data()
        var expectedLength: Int?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let url: URL
    let maximumBytes: Int
    let operation: PublicWebOperation

    init(url: URL, maximumBytes: Int, operation: PublicWebOperation) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.operation = operation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !operation.isFinished else { return }
        do {
            switch unwrapInboundIn(data) {
            case .head(let head): try receive(head)
            case .body(let buffer):
                try state.withLock { state in
                    guard state.response != nil else { throw WebPageError.invalidResponse }
                    guard buffer.readableBytes <= maximumBytes - state.data.count else {
                        throw WebPageError.responseTooLarge
                    }
                    state.data.append(contentsOf: buffer.readableBytesView)
                }
            case .end(let trailers):
                guard trailers == nil || trailers?.isEmpty == true else { throw WebPageError.invalidResponse }
                let result = try state.withLock { state -> (Data, HTTPURLResponse) in
                    guard let response = state.response,
                          state.expectedLength == nil || state.expectedLength == state.data.count else {
                        throw WebPageError.invalidResponse
                    }
                    let data = state.data
                    state.data = Data()
                    return (data, response)
                }
                operation.finish(.success(result))
            }
        } catch { operation.finish(.failure(error as? WebPageError ?? .invalidResponse)) }
    }

    private func receive(_ head: HTTPResponseHead) throws {
        let status = Int(head.status.code)
        guard !(300...399).contains(status) else { throw WebPageError.redirectDenied }
        guard (200...299).contains(status), status != 206 else { throw WebPageError.invalidResponse }
        let fields = head.headers
        for name in ["content-type", "content-length", "content-encoding", "transfer-encoding"] {
            guard fields[name].count <= 1 else { throw WebPageError.invalidResponse }
        }
        let compression = fields.first(name: "content-encoding")?.lowercased()
        guard compression == nil || compression == "identity" else { throw WebPageError.unsupportedCompression }
        let expected = try expectedLength(fields)
        // Whitelist only extraction metadata; cookies and authentication headers never reach the model.
        guard let contentType = fields.first(name: "content-type"),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": contentType]),
              ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
            throw WebPageError.unsupportedContentType
        }
        try state.withLock { state in
            guard state.response == nil else { throw WebPageError.invalidResponse }
            state.response = response
            state.expectedLength = expected
        }
    }

    private func expectedLength(_ fields: HTTPHeaders) throws -> Int? {
        let length = fields.first(name: "content-length")
        let transfer = fields.first(name: "transfer-encoding")?.lowercased()
        guard transfer == nil || (transfer == "chunked" && length == nil) else { throw WebPageError.invalidResponse }
        let expected = length.flatMap(Int.init)
        if let length {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                  let expected, expected >= 0 else { throw WebPageError.invalidResponse }
            guard expected <= maximumBytes else { throw WebPageError.responseTooLarge }
        }
        return expected
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        operation.finish(.failure(error is NIOSSLError ? WebPageError.tlsFailure : .invalidResponse))
    }
    func channelInactive(context: ChannelHandlerContext) {
        operation.finish(.failure(WebPageError.invalidResponse))
        context.fireChannelInactive()
    }
}
