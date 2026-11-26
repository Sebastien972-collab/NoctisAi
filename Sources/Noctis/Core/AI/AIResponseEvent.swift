// Created by Sébastien DAGUIN
import Foundation

/// Presentation events from a single response. Reasoning is emitted only when the model supplies it.
public enum AIResponseEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolStarted(id: String, name: String, arguments: String)
    case toolCompleted(id: String, name: String, result: String, isError: Bool)
}

/// Adapts the legacy text API without leaving a forwarding task alive after scoped consumption.
enum AIResponseStream {
    static func map<Input: Sendable, Output: Sendable>(
        _ source: AsyncThrowingStream<Input, Error>,
        transform: @escaping @Sendable (Input) -> Output?
    ) -> (stream: AsyncThrowingStream<Output, Error>, task: Task<Void, Never>) {
        let (stream, output) = AsyncThrowingStream<Output, Error>.makeStream()
        let task = Task {
            do {
                for try await element in source {
                    try Task.checkCancellation()
                    if let value = transform(element), case .terminated = output.yield(value) { break }
                }
                try Task.checkCancellation()
                output.finish()
            } catch { output.finish(throwing: error) }
        }
        output.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return (stream, task)
    }

    static func consume<Input: Sendable, Output: Sendable>(
        _ source: AsyncThrowingStream<Input, Error>,
        transform: @escaping @Sendable (Input) -> Output?,
        using consume: @Sendable (AsyncThrowingStream<Output, Error>) async throws -> Void
    ) async throws {
        let mapped = map(source, transform: transform)
        do {
            try await consume(mapped.stream)
            try Task.checkCancellation()
        } catch {
            mapped.task.cancel()
            await mapped.task.value
            throw error
        }
        mapped.task.cancel()
        await mapped.task.value
    }

    static func text(_ event: AIResponseEvent) -> String? {
        if case let .textDelta(text) = event { return text }
        return nil
    }
}
