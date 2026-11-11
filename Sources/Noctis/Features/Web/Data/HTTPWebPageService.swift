import Foundation
import SwiftReadability

struct HTTPWebPageService: WebPageService {
    private let maximumCharacters: Int

    init(maximumCharacters: Int = 20_000) {
        self.maximumCharacters = min(20_000, max(1, maximumCharacters))
    }

    func open(url: URL) async throws -> WebPage {
        try Task.checkCancellation()
        _ = try PublicWebURLPolicy.validate(url.absoluteString)
        // Do not replace this with DNS preflight + URLSession: that has a TOCTOU gap.
        // No opt-in flag exists until the actual peer address can be enforced.
        throw WebPageError.publicAccessDisabled
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
        let compression = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard compression == nil || compression == "identity" else {
            throw WebPageError.unsupportedCompression
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
