//
//  MockAIModelService.swift
//  NoctisTests
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import Synchronization
@testable import Noctis

final class MockAIModelService: AIModelService, Sendable {
    enum Call: Equatable, Sendable {
        case load
        case generate(String)
    }

    enum Failure: String, LocalizedError, Sendable {
        case loadFailed = "Chargement simulé impossible."
        case generationFailed = "Génération simulée impossible."
        case streamFailed = "Streaming simulé interrompu."
        case unexpectedGeneration = "Appel de génération non prévu par le test."

        var errorDescription: String? { rawValue }
    }

    enum Response: Sendable {
        case chunks([String], finishingWith: Failure? = nil)
        case failure(Failure)
    }

    private struct State {
        var calls: [Call] = []
        var responseIndex = 0
    }

    private let state = Mutex(State())
    private let loadError: Failure?
    private let responses: [Response]

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    init(loadError: Failure? = nil, responses: [Response] = []) {
        self.loadError = loadError
        self.responses = responses
    }

    func load() async throws {
        state.withLock { $0.calls.append(.load) }

        if let loadError {
            throw loadError
        }
    }

    func generate(prompt: String) throws -> AsyncThrowingStream<String, Error> {
        let index = state.withLock { state in
            state.calls.append(.generate(prompt))
            let index = state.responseIndex
            state.responseIndex += 1
            return index
        }

        guard responses.indices.contains(index) else {
            throw Failure.unexpectedGeneration
        }

        switch responses[index] {
        case .failure(let error):
            throw error
        case .chunks(let chunks, let error):
            return AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish(throwing: error)
            }
        }
    }
}
