//
//  SearchResult.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Foundation

struct SearchResult: Decodable, Sendable {
    let title: String
    let url: URL
    let content: String?
}