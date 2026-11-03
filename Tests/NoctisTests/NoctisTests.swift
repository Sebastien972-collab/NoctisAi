import Foundation
import Testing
@testable import Noctis

private enum TestFailure: Error { case expected }

private actor Signal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor LoadProbe {
    var count = 0
    func record() { count += 1 }
}

private final class MockSession: ModelSession {
    let requests: AsyncStream<AsyncThrowingStream<String, Error>.Continuation>.Continuation
    let terminations: AsyncStream<Void>.Continuation
    let cleanup: Signal?

    init(
        requests: AsyncStream<AsyncThrowingStream<String, Error>.Continuation>.Continuation,
        terminations: AsyncStream<Void>.Continuation,
        cleanup: Signal?
    ) {
        self.requests = requests
        self.terminations = terminations
        self.cleanup = cleanup
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let (stream, output) = AsyncThrowingStream<String, Error>.makeStream()
        let terminations = terminations
        output.onTermination = { _ in terminations.yield(()) }
        requests.yield(output)
        return stream
    }

    func synchronize() async { await cleanup?.wait() }
}

private struct Fixture: Sendable {
    let service: MLXModelService
    let requests: AsyncStream<AsyncThrowingStream<String, Error>.Continuation>
    let terminations: AsyncStream<Void>

    init(cleanup: Signal? = nil, loadStarted: Signal? = nil, loadRelease: Signal? = nil,
         loads: LoadProbe? = nil) {
        let (requests, requestOutput) =
            AsyncStream<AsyncThrowingStream<String, Error>.Continuation>.makeStream()
        let (terminations, terminationOutput) = AsyncStream<Void>.makeStream()
        self.requests = requests
        self.terminations = terminations
        service = MLXModelService(sessionFactory: {
            await loads?.record()
            await loadStarted?.signal()
            await loadRelease?.wait()
            return MockSession(
                requests: requestOutput, terminations: terminationOutput, cleanup: cleanup
            )
        })
    }
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var result = ""
    for try await chunk in stream { result += chunk }
    return result
}

@Suite(.timeLimit(.minutes(1)))
struct ModelConcurrencyTests {
    @Test func generationBeforeLoad() async throws {
        let fixture = Fixture()
        #expect(await fixture.service.loadState == .notLoaded)
        await #expect(throws: MLXModelServiceError.modelNotLoaded) {
            _ = try await fixture.service.generate(prompt: "hello")
        }
    }

    @Test func concurrentGenerationAndNormalCompletion() async throws {
        let fixture = Fixture()
        try await fixture.service.load()
        let first = try await fixture.service.generate(prompt: "first")
        await #expect(throws: MLXModelServiceError.generationInProgress) {
            _ = try await fixture.service.generate(prompt: "second")
        }
        var requests = fixture.requests.makeAsyncIterator()
        let output = try #require(await requests.next())
        output.yield("one")
        output.yield("two")
        output.finish()
        #expect(try await collect(first) == "onetwo")

        let next = try await fixture.service.generate(prompt: "next")
        let nextOutput = try #require(await requests.next())
        nextOutput.finish()
        #expect(try await collect(next).isEmpty)
    }

    @Test func failureReleasesReservation() async throws {
        let fixture = Fixture()
        try await fixture.service.load()
        var requests = fixture.requests.makeAsyncIterator()
        let stream = try await fixture.service.generate(prompt: "first")
        let output = try #require(await requests.next())
        output.finish(throwing: TestFailure.expected)
        await #expect(throws: TestFailure.self) { _ = try await collect(stream) }

        let next = try await fixture.service.generate(prompt: "retry")
        let nextOutput = try #require(await requests.next())
        nextOutput.yield("ok")
        nextOutput.finish()
        #expect(try await collect(next) == "ok")
    }

    @Test func cancellationWaitsForActualCleanup() async throws {
        let cleanup = Signal()
        let received = Signal()
        let fixture = Fixture(cleanup: cleanup)
        try await fixture.service.load()
        var requests = fixture.requests.makeAsyncIterator()
        var terminations = fixture.terminations.makeAsyncIterator()
        let consumer = Task {
            try await fixture.service.withResponse(prompt: "first") { stream in
                for try await _ in stream { await received.signal() }
            }
        }
        let output = try #require(await requests.next())
        output.yield("first")
        await received.wait()
        consumer.cancel()
        _ = await terminations.next()
        await #expect(throws: MLXModelServiceError.generationInProgress) {
            _ = try await fixture.service.generate(prompt: "too early")
        }
        await cleanup.signal()
        await #expect(throws: CancellationError.self) { try await consumer.value }

        let next = try await fixture.service.generate(prompt: "retry")
        let nextOutput = try #require(await requests.next())
        nextOutput.finish()
        _ = try await collect(next)
    }

    @Test func earlyBreakInScopeJoinsProducer() async throws {
        let fixture = Fixture()
        try await fixture.service.load()
        var requests = fixture.requests.makeAsyncIterator()
        let consumer = Task {
            try await fixture.service.withResponse(prompt: "first") { stream in
                for try await _ in stream { break }
            }
        }
        let output = try #require(await requests.next())
        output.yield("first")
        try await consumer.value

        let next = try await fixture.service.generate(prompt: "retry")
        let nextOutput = try #require(await requests.next())
        nextOutput.finish()
        _ = try await collect(next)
    }

    @Test func droppedRawStreamCancelsProducer() async throws {
        let fixture = Fixture()
        try await fixture.service.load()
        var requests = fixture.requests.makeAsyncIterator()
        var terminations = fixture.terminations.makeAsyncIterator()
        // The helper's return drops both the stream and iterator.
        let consumer = Task {
            let stream = try await fixture.service.generate(prompt: "first")
            for try await _ in stream { break }
        }
        let output = try #require(await requests.next())
        output.yield("first")
        try await consumer.value
        _ = await terminations.next()
        await fixture.service.cancelGeneration()
        let next = try await fixture.service.generate(prompt: "retry")
        let nextOutput = try #require(await requests.next())
        nextOutput.finish()
        _ = try await collect(next)
    }

    @Test func cancellationBeforeFirstElement() async throws {
        let fixture = Fixture()
        try await fixture.service.load()
        var requests = fixture.requests.makeAsyncIterator()
        let consumer = Task {
            try await fixture.service.withResponse(prompt: "first") { stream in
                for try await _ in stream {}
            }
        }
        let output = try #require(await requests.next())
        consumer.cancel()
        // The upstream startup barrier is deliberately maintained until this point.
        output.yield("first")
        await #expect(throws: CancellationError.self) { try await consumer.value }
        let next = try await fixture.service.generate(prompt: "next")
        let nextOutput = try #require(await requests.next())
        nextOutput.finish()
        _ = try await collect(next)
    }

    @Test func concurrentLoadIsRejectedAndLoadedIsIdempotent() async throws {
        let started = Signal()
        let release = Signal()
        let loads = LoadProbe()
        let fixture = Fixture(loadStarted: started, loadRelease: release, loads: loads)
        let first = Task { try await fixture.service.load() }
        await started.wait()
        #expect(await fixture.service.loadState == .loading)
        await #expect(throws: MLXModelServiceError.modelLoading) {
            try await fixture.service.load()
        }
        await release.signal()
        try await first.value
        try await fixture.service.load()
        #expect(await loads.count == 1)
        #expect(await fixture.service.loadState == .loaded)

        let stream = try await fixture.service.generate(prompt: "active")
        try await fixture.service.load()
        #expect(await loads.count == 1)
        var requests = fixture.requests.makeAsyncIterator()
        let output = try #require(await requests.next())
        output.finish()
        _ = try await collect(stream)
    }

    @Test func failedLoadCanBeRetried() async throws {
        let loads = LoadProbe()
        let fixture = Fixture()
        let service = MLXModelService(sessionFactory: {
            await loads.record()
            if await loads.count == 1 { throw TestFailure.expected }
            // Return a fresh mock, never a shared mutable session.
            let (_, output) =
                AsyncStream<AsyncThrowingStream<String, Error>.Continuation>.makeStream()
            let (_, termination) = AsyncStream<Void>.makeStream()
            return MockSession(requests: output, terminations: termination, cleanup: nil)
        })
        await #expect(throws: TestFailure.self) { try await service.load() }
        #expect(await service.loadState == .failed)
        try await service.load()
        #expect(await service.loadState == .loaded)
        #expect(await loads.count == 2)
        #expect(await fixture.service.loadState == .notLoaded)
    }

    @Test func cancelledLoadDoesNotStartAnotherLoad() async throws {
        let started = Signal()
        let release = Signal()
        let loads = LoadProbe()
        let fixture = Fixture(loadStarted: started, loadRelease: release, loads: loads)
        let first = Task { try await fixture.service.load() }
        await started.wait()
        first.cancel()
        await #expect(throws: MLXModelServiceError.modelLoading) {
            try await fixture.service.load()
        }
        await release.signal()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await fixture.service.load()
        #expect(await fixture.service.loadState == .loaded)
        #expect(await loads.count == 1)
    }
}
