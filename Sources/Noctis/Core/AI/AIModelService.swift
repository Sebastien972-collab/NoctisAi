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

    /// Consumes text, model reasoning and actual tool activity within the response's cleanup scope.
    func withResponseEvents(
        prompt: String,
        consume: @Sendable (AsyncThrowingStream<AIResponseEvent, Error>) async throws -> Void
    ) async throws

    func generate(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error>
}

public extension AIModelService {
    /// Existing providers keep working and expose only the text they actually produce.
    func withResponseEvents(
        prompt: String,
        consume: @Sendable (AsyncThrowingStream<AIResponseEvent, Error>) async throws -> Void
    ) async throws {
        try await withResponse(prompt: prompt) { stream in
            try await AIResponseStream.consume(stream, transform: { .textDelta($0) }, using: consume)
        }
    }

    func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws {
        progress(.loading)
        try await load()
        progress(.ready)
    }
}
