//
//  MLXChatSession.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//
import Foundation
import MLXLMCommon
import MLXVLM
import HuggingFace
import Tokenizers
import MLXHuggingFace

private final class MLXChatSession: ModelSession {
    private let session: ChatSession

    init(session: ChatSession) {
        self.session = session
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        session.streamResponse(to: prompt)
    }

    func synchronize() async {
        await session.synchronize()
    }
}

actor MLXModelService: AIModelService {
    enum LoadState: Equatable, Sendable {
        case notLoaded, loading, loaded, failed
    }

    private(set) var loadState = LoadState.notLoaded
    private let factory: ModelSessionWorker.Factory
    private var worker: ModelSessionWorker?
    private var generation: Task<Void, Never>?
    private var cancellation: GenerationCancellation?

    init(webSearchService: any WebSearchService = SearXNGService()) {
        let dispatcher = WebToolDispatcher(searchService: webSearchService, pasgeService: HTTPWebPageService())
        factory = {
            let model = try await loadModel(
                from: #hubDownloader,
                using: #huggingFaceTokenizerLoader(),
                id: NoctisConfiguration.modelID
            )
            return MLXChatSession(session: ChatSession(
                model,
                instructions: NoctisIdentity.systemPrompt,
                tools: [WebSearchTool.schema],
                toolDispatch: { call in try await dispatcher.execute(call) }
            ))
        }
    }

    init(sessionFactory: @escaping ModelSessionWorker.Factory) {
        factory = sessionFactory
    }

    func load() async throws {
        try Task.checkCancellation()
        switch loadState {
        case .loaded:
            return
        case .loading:
            throw MLXModelServiceError.modelLoading
        case .notLoaded, .failed:
            break
        }
        loadState = .loading
        do {
            worker = try await ModelSessionWorker.load(factory: factory)
            loadState = .loaded
            // Loading is shared service state: once started, it completes even
            // if its caller cancels, avoiding an overlapping replacement load.
            try Task.checkCancellation()
        } catch {
            if worker == nil { loadState = .failed }
            throw error
        }
    }

    func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        try startGeneration(prompt: prompt).stream
    }

    /// Scoped consumption guarantees cleanup on early return, thrown errors and
    /// cancellation, even if the caller retains a copy of the stream.
    func withResponse(
        prompt: String,
        consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void
    ) async throws {
        let response = try startGeneration(prompt: prompt)
        do {
            try await consume(response.stream)
            try Task.checkCancellation()
        } catch {
            response.cancellation.cancel()
            await response.task.value
            throw error
        }
        response.cancellation.cancel()
        await response.task.value
    }

    private func startGeneration(prompt: String) throws -> (
        stream: AsyncThrowingStream<String, Error>,
        cancellation: GenerationCancellation,
        task: Task<Void, Never>
    ) {
        try Task.checkCancellation()
        guard let worker else { throw MLXModelServiceError.modelNotLoaded }
        guard generation == nil else { throw MLXModelServiceError.generationInProgress }

        let (stream, output) = AsyncThrowingStream<String, Error>.makeStream()
        let cancellation = GenerationCancellation()
        self.cancellation = cancellation
        output.onTermination = { termination in
            if case .cancelled = termination { cancellation.cancel() }
        }
        let task = Task {
            var failure: (any Error)?
            do {
                try await worker.generate(
                    prompt: prompt, output: output, cancellation: cancellation
                )
            } catch {
                failure = error
            }
            self.generation = nil
            self.cancellation = nil
            output.finish(throwing: failure)
        }
        generation = task
        return (stream, cancellation, task)
    }

    /// Waits for MLX's cache transaction to end before permitting another turn.
    func cancelGeneration() async {
        let current = generation
        cancellation?.cancel()
        await current?.value
    }
}
