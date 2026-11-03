//
//  WebSearchService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


public protocol WebSearchService: Sendable {
    func search(query: String) async throws -> [SearchResult]
}