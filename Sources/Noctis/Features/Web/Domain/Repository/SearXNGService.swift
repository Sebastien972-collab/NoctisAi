//
//  SearXNGService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Foundation

struct SearXNGService: WebSearchService {

    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8888")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func search(query: String) async throws -> [SearchResult] {
        let endpoint = baseURL.appendingPathComponent("search")

        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(
            SearXNGResponse.self,
            from: data
        )

        return decoded.results
    }
}

private struct SearXNGResponse: Decodable {
    let results: [SearchResult]
}