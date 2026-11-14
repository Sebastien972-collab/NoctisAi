// Created by Sébastien DAGUIN

import Foundation
import os
import MLXLMCommon

/// Created and used exclusively by the worker task; intentionally not Sendable.
protocol ModelSession: AnyObject {
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error>
    func synchronize() async
    func reset(history: [AIChatMessage]) async throws
}

protocol StructuredModelSession: ModelSession {
    func streamDetails(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec],
        instructions: String
    ) -> AsyncThrowingStream<Generation, Error>
}

final class GenerationCancellation: Sendable {
    private struct State {
        var requested = false
        var armed = false
        var reader: Task<Void, Error>?
    }
    // Keep state synchronized on iOS 17, where Synchronization.Mutex is unavailable.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ reader: Task<Void, Error>) {
        let shouldCancel = state.withLock {
            $0.reader = reader
            return $0.requested && $0.armed
        }
        if shouldCancel { reader.cancel() }
    }

    // The first element proves that MLX has entered its cache transaction.
    // Before this point synchronize() could overtake its unstructured producer.
    func arm() {
        let reader = state.withLock {
            $0.armed = true
            return $0.requested ? $0.reader : nil
        }
        reader?.cancel()
    }

    func cancel() {
        let reader = state.withLock {
            $0.requested = true
            return $0.armed ? $0.reader : nil
        }
        // Cancellation handlers run synchronously and may re-enter this state.
        reader?.cancel()
    }

    var isCancelled: Bool { state.withLock { $0.requested } }

    func clear() { state.withLock { $0.reader = nil } }
}

/// Sendable commands cross this boundary, never the mutable session reference.
final class ModelSessionWorker: Sendable {
    typealias Factory = @Sendable (@escaping @Sendable (AIModelLoadPhase) -> Void) async throws -> any ModelSession

    private struct Request: Sendable {
        let prompt: String
        let output: AsyncThrowingStream<String, Error>.Continuation
        let cancellation: GenerationCancellation
        let completion: CheckedContinuation<Void, Error>
    }

    private final class StructuredInput: @unchecked Sendable {
        let messages: [MLXLMCommon.Chat.Message]
        let tools: [ToolSpec]
        let instructions: String
        init(messages: [MLXLMCommon.Chat.Message], tools: [ToolSpec], instructions: String) {
            self.messages = messages
            self.tools = tools
            self.instructions = instructions
        }
    }

    private struct StructuredRequest: @unchecked Sendable {
        let input: StructuredInput
        let output: AsyncThrowingStream<Generation, Error>.Continuation
        let cancellation: GenerationCancellation
        let completion: CheckedContinuation<Void, Error>
    }

    private enum Command: Sendable {
        case synchronize(CheckedContinuation<Void, Never>)
        case generate(Request)
        case structuredGenerate(StructuredRequest)
        case reset([AIChatMessage], CheckedContinuation<Void, Error>)
    }

    private let requests: AsyncStream<Command>.Continuation

    private init(requests: AsyncStream<Command>.Continuation) {
        self.requests = requests
    }

    deinit { requests.finish() }

    static func load(
        factory: @escaping Factory,
        progress: @escaping @Sendable (AIModelLoadPhase) -> Void
    ) async throws -> ModelSessionWorker {
        try await withCheckedThrowingContinuation { ready in
            let (stream, requests) = AsyncStream<Command>.makeStream()
            // The returned stream API needs a persistent owner. Closing the
            // command channel in deinit terminates this task without a cycle.
            Task {
                do {
                    let session = try await factory(progress)
                    ready.resume(returning: ModelSessionWorker(requests: requests))
                    for await command in stream {
                        await execute(command, session: session)
                    }
                } catch {
                    requests.finish()
                    ready.resume(throwing: error)
                }
            }
        }
    }

    private static func execute(_ command: Command, session: any ModelSession) async {
        switch command {
        case .synchronize(let completion):
            await session.synchronize()
            completion.resume()
        case .reset(let history, let completion):
            do {
                try await session.reset(history: history)
                completion.resume()
            } catch {
                completion.resume(throwing: error)
            }
        case .structuredGenerate(let request): await structured(request, session: session)
        case .generate(let request): await generate(request, session: session)
        }
    }

    private static func structured(_ request: StructuredRequest, session: any ModelSession) async {
        if request.cancellation.isCancelled {
            request.completion.resume(throwing: CancellationError())
            return
        }
        guard let session = session as? any StructuredModelSession else {
            request.completion.resume(throwing: MLXModelServiceError.modelNotLoaded)
            return
        }
        let upstream = session.streamDetails(
            messages: request.input.messages, tools: request.input.tools,
            instructions: request.input.instructions
        )
        let reader = Task {
            for try await event in upstream {
                request.cancellation.arm()
                if request.cancellation.isCancelled { continue }
                if case .terminated = request.output.yield(event) {
                    request.cancellation.cancel()
                }
            }
            try Task.checkCancellation()
        }
        request.cancellation.install(reader)
        let result = await reader.result
        await session.synchronize()
        request.cancellation.clear()
        if request.cancellation.isCancelled {
            request.completion.resume(throwing: CancellationError())
        } else {
            request.completion.resume(with: result)
        }
    }

    private static func generate(_ request: Request, session: any ModelSession) async {
        if request.cancellation.isCancelled {
            request.completion.resume(throwing: CancellationError())
            return
        }
        let upstream = session.streamResponse(to: request.prompt)
        let reader = Task {
            for try await chunk in upstream {
                request.cancellation.arm()
                // Re-enter next() to trigger upstream onTermination.
                if request.cancellation.isCancelled { continue }
                if case .terminated = request.output.yield(chunk) {
                    request.cancellation.cancel()
                }
            }
            try Task.checkCancellation()
        }
        request.cancellation.install(reader)
        let result = await reader.result
        // Cancelling an iterator does not join MLX's producer.
        await session.synchronize()
        request.cancellation.clear()
        if request.cancellation.isCancelled {
            request.completion.resume(throwing: CancellationError())
        } else {
            request.completion.resume(with: result)
        }
    }

    func generate(
        prompt: String,
        output: AsyncThrowingStream<String, Error>.Continuation,
        cancellation: GenerationCancellation
    ) async throws {
        try await withCheckedThrowingContinuation { completion in
            let request = Request(
                prompt: prompt, output: output,
                cancellation: cancellation, completion: completion
            )
            if case .terminated = requests.yield(.generate(request)) {
                completion.resume(throwing: CancellationError())
            }
        }
    }

    func synchronize() async {
        await withCheckedContinuation { completion in
            if case .terminated = requests.yield(.synchronize(completion)) { completion.resume() }
        }
    }

    func reset(history: [AIChatMessage]) async throws {
        try await withCheckedThrowingContinuation { completion in
            if case .terminated = requests.yield(.reset(history, completion)) {
                completion.resume(throwing: CancellationError())
            }
        }
    }

    func streamDetails(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec],
        instructions: String
    ) -> AsyncThrowingStream<Generation, Error> {
        let (stream, output) = AsyncThrowingStream<Generation, Error>.makeStream()
        let cancellation = GenerationCancellation()
        let input = StructuredInput(messages: messages, tools: tools, instructions: instructions)
        Task {
            do {
                try await withCheckedThrowingContinuation { completion in
                    let request = StructuredRequest(
                        input: input, output: output, cancellation: cancellation, completion: completion
                    )
                    if case .terminated = requests.yield(.structuredGenerate(request)) {
                        completion.resume(throwing: CancellationError())
                    }
                }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        output.onTermination = { termination in
            if case .cancelled = termination { cancellation.cancel() }
        }
        return stream
    }
}

/// One lease covers an entire response, including tool execution and cancellation cleanup.
final class ModelGenerationAccess: Sendable {
    private struct State {
        var revision = 0
        var lease: UUID?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var revision: Int { state.withLock { $0.revision } }

    func acquire(revision: Int? = nil) throws -> UUID {
        try state.withLock { state in
            if let revision, revision != state.revision { throw MLXModelServiceError.sessionInvalidated }
            guard state.lease == nil else { throw MLXModelServiceError.generationInProgress }
            let lease = UUID()
            state.lease = lease
            return lease
        }
    }

    func validate(_ lease: UUID, revision: Int) throws {
        try state.withLock { state in
            guard state.revision == revision, state.lease == lease else {
                throw MLXModelServiceError.sessionInvalidated
            }
        }
    }

    func release(_ lease: UUID) { state.withLock { if $0.lease == lease { $0.lease = nil } } }
    func invalidate() { state.withLock { $0.revision += 1 } }
}
