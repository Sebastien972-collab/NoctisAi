//
//  ExternalWebPage.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 05/11/2026.
//

import Foundation

struct ExternalWebPage: Codable, Sendable {
    let trust: String
    let instructions: String
    let title: String
    let url: String
    let content: String
    let isTruncated: Bool
}
