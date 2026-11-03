//
//  SearchResult.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Foundation

public struct SearchResult: Decodable, Sendable {
    public let title: String
    public let url: URL
    public let content: String?

    public init(title: String, url: URL, content: String? = nil) {
        self.title = title
        self.url = url
        self.content = content
    }
}