import Foundation
import SwiftReadability
import SwiftSoup

struct HTTPWebPageService: WebPageService {
    private let maximumCharacters: Int
    private let transport: SecureWebTransport

    init(maximumCharacters: Int = 20_000, transport: SecureWebTransport = .shared) {
        self.transport = transport
        self.maximumCharacters = min(20_000, max(1, maximumCharacters))
    }

    func open(url: URL) async throws -> WebPage {
        try Task.checkCancellation()
        let checkedURL = try PublicWebURLPolicy.validate(url.absoluteString)
        let (data, response) = try await transport.get(checkedURL)
        return try await WebPageExtraction.shared.extract(service: self, data: data, response: response)
    }

    /// Bounded offline extraction; it never executes scripts or loads secondary resources.
    func extract(data: Data, response: HTTPURLResponse) throws -> WebPage {
        try Task.checkCancellation()
        guard data.count <= 2 * 1_024 * 1_024 else { throw WebPageError.responseTooLarge }
        guard (200...299).contains(response.statusCode), response.statusCode != 206,
              let url = response.url else { throw WebPageError.invalidResponse }
        _ = try PublicWebURLPolicy.validate(url.absoluteString)
        guard ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
            throw WebPageError.unsupportedContentType
        }
        let compression = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard compression == nil || compression == "identity" else {
            throw WebPageError.unsupportedCompression
        }
        let encoding = try textEncoding(response)
        guard let html = String(data: data, encoding: encoding) else { throw WebPageError.invalidEncoding }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebPageError.noContent
        }
        let document = try boundedDocument(html: html, url: url)
        let reader = Readability(document: document, options: ReadabilityOptions(
            maxElemsToParse: 20_000,
            serializer: { _ in "" },
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

    private func textEncoding(_ response: HTTPURLResponse) throws -> String.Encoding {
        let encoding: String.Encoding
        switch response.textEncodingName?.lowercased() ?? "utf-8" {
        case "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1", "windows-1252": encoding = .windowsCP1252
        case "us-ascii": encoding = .ascii
        default: throw WebPageError.invalidEncoding
        }
        return encoding
    }

    private func boundedDocument(html: String, url: URL) throws -> Document {
        // Conservative preflight also bounds markup before SwiftSoup constructs its DOM.
        guard html.utf8.lazy.filter({ $0 == 60 }).prefix(20_001).count <= 20_000 else {
            throw WebPageError.responseTooLarge
        }
        let document = try SwiftSoup.parse(html, url.absoluteString)
        var pending: [(Node, Int)] = [(document, 0)]
        var count = 0
        while let (node, depth) = pending.popLast() {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000, depth <= 128 else { throw WebPageError.responseTooLarge }
            for child in node.getChildNodes() { pending.append((child, depth + 1)) }
        }
        return document
    }

}

private actor WebPageExtraction {
    static let shared = WebPageExtraction()
    private var active = 0

    func extract(service: HTTPWebPageService, data: Data, response: HTTPURLResponse) async throws -> WebPage {
        try Task.checkCancellation()
        guard active < 2 else { throw WebPageError.requestLimit }
        active += 1
        defer { active -= 1 }
        let task = Task.detached(priority: .utility) { try service.extract(data: data, response: response) }
        return try await withTaskCancellationHandler {
            let page = try await task.value
            try Task.checkCancellation()
            return page
        } onCancel: { task.cancel() }
    }
}
