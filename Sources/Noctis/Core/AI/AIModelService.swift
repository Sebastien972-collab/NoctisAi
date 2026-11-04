//
//  AIModelService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

public protocol AIModelService: Sendable {
    func load() async throws
    func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws
    func resetConversation(history: [AIChatMessage]) async throws
    func cancelGeneration() async

    func withResponse(
        prompt: String,
        consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void
    ) async throws

    func generate(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error>
}

public extension AIModelService {
    func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws {
        progress(.loading)
        try await load()
        progress(.ready)
    }
}
