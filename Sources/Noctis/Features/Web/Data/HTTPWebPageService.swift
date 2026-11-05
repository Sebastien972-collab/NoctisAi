import Foundation
import SafeURLKit
import SwiftReadability

struct HTTPWebPageService: WebPageService {
    private let client: BoundedHTTPClient
    private let protocolClasses: [AnyClass]?
    private let maximumCharacters: Int

    init(
        client: BoundedHTTPClient? = nil,
        limits: HTTPResponseLimits? = nil,
        protocolClasses: [AnyClass]? = nil,
        maximumCharacters: Int = 20_000
    ) {
        let effectiveLimits = limits ?? (try! HTTPResponseLimits())
        self.client = client ?? BoundedHTTPClient(limits: effectiveLimits, enforcePublicPeer: true)
        self.protocolClasses = protocolClasses
        self.maximumCharacters = min(20_000, max(1, maximumCharacters))
    }

    func open(url: URL) async throws -> WebPage {
        try Task.checkCancellation()
        let validatedURL = try PublicWebURLPolicy.validate(url.absoluteString)

        if protocolClasses == nil, let host = validatedURL.host {
            try Self.validateDNSResolution(host: host)
        }

        let (data, response) = try await client.get(
            validatedURL,
            mimeTypes: ["text/html", "application/xhtml+xml"],
            protocolClasses: protocolClasses
        )
        return try extract(data: data, response: response)
    }

    static func validateDNSResolution(host: String) throws {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "443", &hints, &res)
        guard status == 0, let first = res else {
            throw WebPageError.invalidURL
        }
        defer { freeaddrinfo(res) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            let family = info.pointee.ai_family
            if family == AF_INET {
                let sin = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ipRaw = UInt32(bigEndian: sin.sin_addr.s_addr)
                let ipv4 = IPv4Address(rawValue: ipRaw)
                if SpecialPurposeAddresses.match(ipv4) != nil {
                    throw WebPageError.invalidURL
                }
            } else if family == AF_INET6 {
                let sin6 = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var addr = sin6.sin6_addr
                let bytes = withUnsafeBytes(of: &addr) { Array($0) }
                if bytes.count == 16 {
                    var pieces: [UInt16] = []
                    for i in stride(from: 0, to: 16, by: 2) {
                        let piece = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
                        pieces.append(piece)
                    }
                    if let ipv6 = IPv6Address(pieces: pieces), SpecialPurposeAddresses.match(ipv6) != nil {
                        throw WebPageError.invalidURL
                    }
                }
            }
            current = info.pointee.ai_next
        }
    }

    /// Offline extraction retained until an audited public transport is available.
    func extract(data: Data, response: HTTPURLResponse) throws -> WebPage {
        try Task.checkCancellation()
        guard data.count <= 2 * 1_024 * 1_024 else { throw WebPageError.responseTooLarge }
        guard (200...299).contains(response.statusCode), response.statusCode != 206,
              let url = response.url else { throw WebPageError.invalidResponse }
        _ = try PublicWebURLPolicy.validate(url.absoluteString)
        guard ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
            throw WebPageError.unsupportedContentType
        }
        let encoding: String.Encoding
        switch response.textEncodingName?.lowercased() ?? "utf-8" {
        case "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1", "windows-1252": encoding = .windowsCP1252
        case "us-ascii": encoding = .ascii
        default: throw WebPageError.invalidEncoding
        }
        guard let html = String(data: data, encoding: encoding) else { throw WebPageError.invalidEncoding }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebPageError.noContent
        }
        let reader = Readability(html: html, url: url, options: ReadabilityOptions(
            maxElemsToParse: 20_000,
            extensions: [.imageCarouselRecovery, .publisherChromeCleanup]
        ))
        do {
            guard let article = try reader.parse() else { throw WebPageError.noContent }
            let text = article.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw WebPageError.noContent }
            try Task.checkCancellation()
            let title = article.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WebPage(
                url: url.absoluteString,
                title: String((title.flatMap { $0.isEmpty ? nil : $0 } ?? "Pas de titre trouvé pour cette page").prefix(512)),
                content: String(text.prefix(maximumCharacters)),
                isTruncated: text.count > maximumCharacters
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebPageError.noContent
        }
    }
}
