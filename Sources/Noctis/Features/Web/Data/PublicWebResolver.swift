// Created by Sébastien DAGUIN

import Darwin
import Foundation
import NIOCore
import SafeURLKit

protocol PublicWebResolving: Sendable {
    func resolve(host: String, on eventLoop: any EventLoop) -> EventLoopFuture<[SocketAddress]>
}

/// At most two resolver workers remain occupied even when a caller cancels or times out.
struct PublicWebResolver: PublicWebResolving {
    private static let queue = DispatchQueue(label: "noctis.public-dns", qos: .utility, attributes: .concurrent)
    private static let slots = DispatchSemaphore(value: 2)

    func resolve(host: String, on eventLoop: any EventLoop) -> EventLoopFuture<[SocketAddress]> {
        let promise = eventLoop.makePromise(of: [SocketAddress].self)
        guard Self.slots.wait(timeout: .now()) == .success else {
            promise.fail(WebPageError.requestLimit)
            return promise.futureResult
        }
        Self.queue.async {
            defer { Self.slots.signal() }
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            hints.ai_flags = AI_NUMERICSERV
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                promise.fail(WebPageError.transportFailure)
                return
            }
            defer { freeaddrinfo(first) }
            var addresses: [SocketAddress] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let item = cursor {
                let record = item.pointee
                guard addresses.count < 64 else {
                    promise.fail(WebPageError.invalidResponse)
                    return
                }
                if record.ai_family == AF_INET, let address = record.ai_addr {
                    addresses.append(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        SocketAddress($0.pointee)
                    })
                } else if record.ai_family == AF_INET6, let address = record.ai_addr {
                    addresses.append(address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        SocketAddress($0.pointee)
                    })
                } else {
                    promise.fail(WebPageError.invalidURL)
                    return
                }
                cursor = record.ai_next
            }
            promise.succeed(addresses)
        }
        return promise.futureResult
    }
}

struct PublicWebDestination: Sendable {
    let url: URL
    let address: SocketAddress

    init(url: URL, addresses: [SocketAddress]) throws {
        self.url = try PublicWebURLPolicy.validate(url.absoluteString)
        guard !addresses.isEmpty, addresses.count <= 64 else { throw WebPageError.invalidURL }
        do {
            let hosts = try addresses.map { address -> URLHost in
                if case .v6(let value) = address, value.address.sin6_scope_id != 0 {
                    throw WebPageError.invalidURL
                }
                guard address.port == 443, let numericIP = address.ipAddress, !numericIP.contains("%") else {
                    throw WebPageError.invalidURL
                }
                return try URLHost.parse(numericIP.contains(":") ? "[\(numericIP)]" : numericIP)
            }
            try URLPolicy().validate(resolvedAddresses: hosts)
        } catch { throw WebPageError.invalidURL }
        // Respect the resolver's ordering, without retrying or resolving the name again.
        address = addresses[0]
    }
}
