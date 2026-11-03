//
//  AIModelService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

protocol AIModelService: Sendable {
    func load() async throws

    func generate(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error>
}
