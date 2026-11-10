//
//  WebPage.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

struct WebPage: Sendable {
    let url: String
    let title: String
    let content: String
    let isTruncated: Bool
}
