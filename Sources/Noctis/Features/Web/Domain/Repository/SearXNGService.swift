import Foundation

struct SearXNGService: WebSearchService {
    private let baseURL: URL?
    private let limits: HTTPResponseLimits?
    // Injection is only for deterministic URLProtocol tests; no session with shared credentials.
    private let protocolClasses: [AnyClass]?

    init(baseURL: URL? = URL(string: "http://127.0.0.1:8888"),
         limits: HTTPResponseLimits? = nil,
         protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        self.limits = limits
        self.protocolClasses = protocolClasses
    }

    func search(query: String) async throws -> [SearchResult] {
        try Task.checkCancellation()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.count <= 300, query.utf8.count <= 1_200,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WebToolError.invalidArguments
        }
        // The model never controls this endpoint. Only canonical IPv4 loopback is
        // accepted, so this internal exception needs no DNS and cannot migrate hosts.
        guard let baseURL, let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              base.scheme == "http", base.percentEncodedHost == "127.0.0.1",
              let port = base.port, (1...65535).contains(port),
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/" else {
            throw WebPageError.invalidConfiguration
        }
        var components = base
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw WebPageError.invalidConfiguration }
        let client = BoundedHTTPClient(limits: try limits ?? HTTPResponseLimits())
        let (data, _) = try await client.get(url, mimeTypes: ["application/json"], protocolClasses: protocolClasses)
        do {
            return try JSONDecoder().decode(SearXNGResponse.self, from: data).results
        } catch {
            throw WebPageError.invalidResponse
        }
    }
}

private struct SearXNGResponse: Decodable {
    let results: [SearchResult]
}
