//
//  HTTPWebPageService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import SwiftSoup

struct HTTPWebPageService: WebPageService {
    
    private let session: URLSession
    
    private let maximumCharacters: Int
    
    init(
        session: URLSession = .shared,
        maximumCharacters: Int = 20_000
    ) {
        
        self.session = session
        self.maximumCharacters = maximumCharacters
    }
    
    func open(url: URL) async throws -> WebPage {
        
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw WebPageError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        
        let (data, response) = try await session.data(for: request)
        
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw WebPageError.invalidResponse
        }
        
        guard let contentType = response.value(
            forHTTPHeaderField: "Content-Type"
        )?.lowercased(),
              contentType.contains("text/html") else {
            throw WebPageError.unsupportedContentType
        }
        
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebPageError.invalidEncoding
        }
        
        let document = try SwiftSoup.parse(html)
        
        try document.select(
            "script, style, nav, footer, header, noscript"
            
        ).remove()
        
        let title = try document.title()
        
        let text = try document.body()?.text() ?? ""
        
        let truncated = text.count > maximumCharacters
        
        let content = String(text.prefix(maximumCharacters))
        
        return WebPage(
            url: (response.url ?? url).absoluteString,
            title: title,
            content: content,
            isTruncated: truncated
        )
    }
    
}
