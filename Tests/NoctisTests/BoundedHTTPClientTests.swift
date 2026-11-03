import Foundation
import Testing
@testable import Noctis

/// No mutable global handler and no real connection: scenario is encoded in the URL.
final class WebFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value ?? url.lastPathComponent
        if scenario == "timeout" || scenario == "interrupted" {
            client?.urlProtocol(self, didFailWithError: URLError(scenario == "timeout" ? .timedOut : .networkConnectionLost))
            return
        }
        if scenario == "wait" { return } // Explicitly cancelled by the test.
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        var status = 200
        var body = Data("<html><body>hello</body></html>".utf8)
        switch scenario {
        case "404": status = 404
        case "500": status = 500
        case "206": status = 206
        case "redirect": status = 302; headers["Location"] = "http://127.0.0.1"
        case "mime": headers["Content-Type"] = "application/octet-stream"
        case "spoofmime": headers["Content-Type"] = "application/text/html-fake"
        case "gzip": headers["Content-Encoding"] = "gzip"
        case "declaredLarge": headers["Content-Length"] = "2097153"
        case "finalURL": break
        case "wrongLength": headers["Content-Length"] = "1"
        case "negativeLength": headers["Content-Length"] = "-1"
        case "json":
            headers["Content-Type"] = "application/json"
            body = Data(#"{"results":[{"title":"Swift","url":"https://www.swift.org","content":"Documentation"}]}"#.utf8)
        default: break
        }
        guard let response = HTTPURLResponse(url: scenario == "finalURL" ? url.appendingPathComponent("changed") : url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if scenario == "large" {
            let chunk = Data(repeating: 65, count: 65_536)
            for _ in 0..<33 { client?.urlProtocol(self, didLoad: chunk) }
        } else {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct BoundedHTTPClientTests {
    private func fetch(_ scenario: String) async throws -> Data {
        let url = try #require(URL(string: "https://www.swift.org/" + scenario))
        let (data, _) = try await BoundedHTTPClient(limits: HTTPResponseLimits())
            .get(url, mimeTypes: ["text/html"], protocolClasses: [WebFixtureProtocol.self])
        return data
    }

    @Test func htmlWithoutContentLength() async throws {
        #expect(try await fetch("html") == Data("<html><body>hello</body></html>".utf8))
    }

    @Test(arguments: [
        ("404", WebPageError.invalidResponse), ("500", .invalidResponse), ("206", .invalidResponse),
        ("mime", .unsupportedContentType), ("spoofmime", .unsupportedContentType),
        ("large", .responseTooLarge), ("declaredLarge", .responseTooLarge),
        ("wrongLength", .invalidResponse), ("negativeLength", .invalidResponse),
        ("gzip", .unsupportedCompression), ("redirect", .redirectDenied),
        ("timeout", .timedOut), ("interrupted", .transportFailure), ("finalURL", .invalidResponse)
    ])
    func controlledFailures(_ scenario: String, _ error: WebPageError) async {
        await #expect(throws: error) { try await fetch(scenario) }
    }

    @Test func cancellationDuringReception() async throws {
        let task = Task { try await fetch("wait") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationBeforeReception() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fetch("html")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func localSearchStillDecodes() async throws {
        let results = try await SearXNGService(protocolClasses: [WebFixtureProtocol.self]).search(query: "json")
        #expect(results.count == 1)
        #expect(results.first?.title == "Swift")
    }

    @Test(arguments: ["http://localhost:8888", "http://127.0.0.1:8888/other",
                      "http://127.0.0.1:8888?url=x", "http://user:password@127.0.0.1:8888",
                      "https://www.swift.org", "http://169.254.169.254:80"])
    func internalExceptionIsNotGeneral(_ raw: String) async throws {
        let baseURL = try #require(URL(string: raw))
        await #expect(throws: WebPageError.invalidConfiguration) {
            try await SearXNGService(baseURL: baseURL, protocolClasses: [WebFixtureProtocol.self]).search(query: "json")
        }
    }
}
