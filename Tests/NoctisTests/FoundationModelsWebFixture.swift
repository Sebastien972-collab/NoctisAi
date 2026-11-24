// Created by Sébastien DAGUIN
import Foundation
import os
@testable import Noctis

/// Only synthesis is simulated. Every tool proposal comes from the production bridge.
final class FoundationModelsWebFixtureClient: NoctisAgentLLMClient {
    private let access = ModelGenerationAccess()
    private let state = OSAllocatedUnfairLock(initialState: [FoundationModelsBridge.PreparedRequest]())
    var providerIdentifier: ProviderIdentifier { .foundationModels }
    var requests: [FoundationModelsBridge.PreparedRequest] { state.withLock { $0 } }

    func beginRun() throws -> UUID { try access.acquire(revision: 0) }
    func endRun(_ lease: UUID) { access.release(lease) }

    func generate(
        messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        throw TransportError.other("This fixture exercises the AgentLoop streaming path")
    }

    func stream(
        messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { output in
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    guard let lease = requestContext?.modelLease else {
                        throw MLXModelServiceError.sessionInvalidated
                    }
                    try access.validate(lease, revision: 0)
                    let request = try FoundationModelsBridge.prepare(messages: messages, tools: tools,
                        context: requestContext, instructions: "Answer the current user using completed tool results.")
                    state.withLock { $0.append(request) }
                    if let call = request.proposedToolCall {
                        output.yield(.toolCallStart(index: 0, id: call.id, name: call.name, kind: call.kind))
                        output.yield(.toolCallDelta(index: 0, arguments: call.arguments))
                    } else {
                        let results = FoundationModelsWebFixture.currentResults(in: messages)
                        let answer = results.isEmpty ? "MODEL_RESPONSE: \(request.prompt)"
                            : "MODEL_SYNTHESIS: \(results.joined(separator: "\n"))"
                        output.yield(.content(answer))
                    }
                    output.yield(.finished(usage: nil))
                    output.yield(.streamClosed(terminalMarkerSeen: true))
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }
}

actor FoundationModelsWebFixtureSearch: WebSearchService {
    enum Behavior: Sendable { case succeeds, fails, suspends }

    private let behavior: Behavior
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private(set) var queries: [String] = []
    private(set) var cancellations = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        started = stream
        signal = continuation
    }

    func search(query: String) async throws -> [SearchResult] {
        queries.append(query)
        signal.yield(())
        switch behavior {
        case .fails:
            throw WebPageError.transportFailure
        case .suspends:
            do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError {
                cancellations += 1
                throw CancellationError()
            }
            throw WebPageError.timedOut
        case .succeeds:
            guard let url = URL(string: "https://example.com/source-\(queries.count)") else {
                throw WebPageError.invalidURL
            }
            return [SearchResult(title: "SOURCE_\(queries.count)", url: url, content: "Verified fixture excerpt")]
        }
    }
}

private struct FoundationModelsWebFixturePage: WebPageService {
    func open(url: URL) async throws -> WebPage {
        throw TransportError.other("No page access is expected by these regression tests")
    }
}

struct FoundationModelsWebFixture {
    let client = FoundationModelsWebFixtureClient()
    let search: FoundationModelsWebFixtureSearch
    let agent: NoctisCLIAgent

    init(_ behavior: FoundationModelsWebFixtureSearch.Behavior = .succeeds,
         registry: NoctisToolRegistry = NoctisToolRegistry()) {
        let search = FoundationModelsWebFixtureSearch(behavior)
        self.search = search
        agent = NoctisCLIAgent(client: client, registry: registry,
            web: WebToolDispatcher(searchService: search, pasgeService: FoundationModelsWebFixturePage()))
    }

    func run(_ prompt: String, history: [ChatMessage] = []) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in agent.stream(prompt: prompt, history: history) { events.append(event) }
        return events
    }

    static func text(in events: [StreamEvent]) -> String {
        events.compactMap { if case let .delta(text) = $0.kind { text } else { nil } }.joined()
    }

    static func results(in messages: [ChatMessage]) -> [String] {
        messages.compactMap { message in
            if case let .tool(_, name, content) = message, name == WebSearchTool.name { content } else { nil }
        }
    }

    static func currentResults(in messages: [ChatMessage]) -> [String] {
        let userIndex = messages.lastIndex { message in
            switch message {
            case .user, .userMultimodal: true
            default: false
            }
        }
        guard let userIndex else { return [] }
        return results(in: Array(messages.dropFirst(userIndex + 1)))
    }
}
