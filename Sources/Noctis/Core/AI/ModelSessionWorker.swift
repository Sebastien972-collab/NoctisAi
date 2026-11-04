// Created by Sébastien DAGUIN

import Foundation
import os

/// Created and used exclusively by the worker task; intentionally not Sendable.
protocol ModelSession: AnyObject {
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error>
    func synchronize() async
    func reset(history: [AIChatMessage]) async throws
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
        state.withLock {
            $0.reader = reader
            if $0.requested && $0.armed { reader.cancel() }
        }
    }

    // The first element proves that MLX has entered its cache transaction.
    // Before this point synchronize() could overtake its unstructured producer.
    func arm() {
        state.withLock {
            $0.armed = true
            if $0.requested { $0.reader?.cancel() }
        }
    }

    func cancel() {
        state.withLock {
            $0.requested = true
            if $0.armed { $0.reader?.cancel() }
        }
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

    private enum Command: Sendable {
        case generate(Request)
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
                        switch command {
                        case .reset(let history, let completion):
                            do {
                                try await session.reset(history: history)
                                completion.resume()
                            } catch {
                                completion.resume(throwing: error)
                            }
                        case .generate(let request):
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
                    }
                } catch {
                    requests.finish()
                    ready.resume(throwing: error)
                }
            }
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

    func reset(history: [AIChatMessage]) async throws {
        try await withCheckedThrowingContinuation { completion in
            if case .terminated = requests.yield(.reset(history, completion)) {
                completion.resume(throwing: CancellationError())
            }
        }
    }
}
