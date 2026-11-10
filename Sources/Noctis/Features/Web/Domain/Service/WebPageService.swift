//
//  WebPageService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

protocol WebPageService: Sendable {
    func open(url: URL) async throws -> WebPage
}
