// Created by Sébastien DAGUIN

import Foundation
import Testing
import NoctisAgent
import os
@testable import Noctis

private enum LocalProviderStep: Sendable {
    case text(String)
    case call(ToolCall)
    case pause
}

/// A provider that only proposes calls; it has no workspace or tool executor.
private final class LocalProviderFixtureClient: NoctisAgentLLMClient {
    struct State {
        var scripts: [[LocalProviderStep]]
        var histories: [[ChatMessage]] = []
        var toolNames: [[String]] = []
    }

    let access: ModelGenerationAccess
    let state: OSAllocatedUnfairLock<State>
    private let revision: Int
    var providerIdentifier: ProviderIdentifier { .foundationModels }

    init(_ scripts: [[LocalProviderStep]]) {
        let access = ModelGenerationAccess()
        self.access = access
        state = OSAllocatedUnfairLock(initialState: State(scripts: scripts))
        revision = access.revision
    }

    func beginRun() throws -> UUID { try access.acquire(revision: revision) }
    func endRun(_ lease: UUID) { access.release(lease) }

    func generate(
        messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        throw TransportError.other("This fixture requires the AgentLoop streaming path")
    }

    func stream(
        messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                do {
                    guard let lease = requestContext?.modelLease else {
                        throw MLXModelServiceError.sessionInvalidated
                    }
                    try access.validate(lease, revision: revision)
                    let steps = state.withLock { state in
                        state.histories.append(messages)
                        state.toolNames.append(tools.map(\.name))
                        return state.scripts.isEmpty ? [] : state.scripts.removeFirst()
                    }
                    try await Self.produce(steps, output: output)
                    output.yield(.finished(usage: nil))
                    output.yield(.streamClosed(terminalMarkerSeen: true))
                    output.finish()
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    private static func produce(
        _ steps: [LocalProviderStep], output: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        var callIndex = 0
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case .text(let text):
                output.yield(.content(text))
            case .call(let call):
                output.yield(.toolCallStart(index: callIndex, id: call.id, name: call.name, kind: call.kind))
                output.yield(.toolCallDelta(index: callIndex, arguments: call.arguments))
                callIndex += 1
            case .pause:
                try await Task.sleep(for: .seconds(30))
            }
        }
    }
}

private struct UnusedLocalProviderSearch: WebSearchService {
    func search(query: String) async throws -> [SearchResult] {
        throw TransportError.other("Unexpected web search in a local provider fixture")
    }
}

private struct UnusedLocalProviderPage: WebPageService {
    func open(url: URL) async throws -> WebPage {
        throw TransportError.other("Unexpected page access in a local provider fixture")
    }
}

private struct LocalProviderFixture {
    let directory: URL
    let client: LocalProviderFixtureClient
    let agent: NoctisCLIAgent

    init(_ scripts: [[LocalProviderStep]], workspaceEnabled: Bool = true) throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("LOCAL_PROVIDER_CONTENT".utf8).write(to: directory.appendingPathComponent("example.swift"))
        client = LocalProviderFixtureClient(scripts)
        let workspace = try AuthorizedWorkspace(authorizing: directory)
        let registry = NoctisToolRegistry(workspace: workspaceEnabled ? ToolRegistry(workspace: workspace) : nil)
        agent = NoctisCLIAgent(
            client: client, registry: registry,
            web: WebToolDispatcher(searchService: UnusedLocalProviderSearch(), pasgeService: UnusedLocalProviderPage())
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func run(_ prompt: String, history: [ChatMessage] = []) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in agent.stream(prompt: prompt, history: history) { events.append(event) }
        return events
    }

    static func read(_ path: String = "example.swift") -> LocalProviderStep {
        .call(ToolCall(id: "read00001", name: "readFile", arguments: "{\"path\":\"\(path)\"}"))
    }
}

@Suite("Provider-independent AgentLoop integration", .timeLimit(.minutes(1)))
struct LocalProviderAgentTests {
    @Test func proposedToolExecutesOnceAndItsResultReturnsInHistory() async throws {
        let fixture = try LocalProviderFixture([
            [LocalProviderFixture.read()], [.text("Lecture terminée")], [.text("Suite")]
        ])
        defer { fixture.cleanup() }

        let events = try await fixture.run("Lis le fichier")
        let completed = events.filter { if case .toolCallCompleted = $0.kind { true } else { false } }
        #expect(completed.count == 1)
        let traces = fixture.agent.traceRecorder.events().compactMap(\.tool)
        #expect(traces.filter { $0.status == .executing }.count == 1)
        #expect(traces.last?.status == .succeeded)
        let requests = fixture.client.state.withLock { $0.histories }
        #expect(requests.count == 2)
        #expect(toolResults(in: requests.last ?? []).count == 1)
        #expect(toolResults(in: requests.last ?? []).first?.contains("LOCAL_PROVIDER_CONTENT") == true)

        let history = try #require(fixture.agent.recoveryHistory)
        #expect(history.last == .assistant(AssistantMessage(content: "Lecture terminée")))
        _ = try await fixture.run("Continue", history: history)
        #expect(fixture.client.state.withLock { $0.histories.last } == history + [.user("Continue")])
        #expect(toolResults(in: try #require(fixture.agent.recoveryHistory)).count == 1)
    }

    @Test func providerCannotReadWithoutWorkspaceOrEscapeItsAuthorizedDirectory() async throws {
        for workspaceEnabled in [false, true] {
            let path = workspaceEnabled ? "../outside.swift" : "example.swift"
            let fixture = try LocalProviderFixture([
                [LocalProviderFixture.read(path)], [.text("Lecture refusée")]
            ], workspaceEnabled: workspaceEnabled)
            defer { fixture.cleanup() }

            let events = try await fixture.run("Lis le fichier")
            let results = events.compactMap { event -> ToolResult? in
                if case .toolCallCompleted(_, _, let result) = event.kind { result } else { nil }
            }
            #expect(results.count == 1)
            #expect(results.allSatisfy(\.isError))
            #expect(results.allSatisfy { !$0.content.contains("LOCAL_PROVIDER_CONTENT") })
            let traces = fixture.agent.traceRecorder.events().compactMap(\.tool)
            #expect(!traces.contains { $0.status == .succeeded })
            if workspaceEnabled {
                #expect(traces.last?.status == .refused)
                #expect(traces.last?.reason == .permissionDenied)
            } else {
                #expect(fixture.client.state.withLock { $0.toolNames.allSatisfy { !$0.contains("readFile") } })
                #expect(!traces.contains { $0.status == .executing })
            }
        }
    }

    @Test func invalidatedProviderCannotStartAnotherRun() async throws {
        let fixture = try LocalProviderFixture([[LocalProviderFixture.read()], [.text("Réponse interdite")]])
        defer { fixture.cleanup() }
        fixture.client.access.invalidate()

        await #expect(throws: MLXModelServiceError.sessionInvalidated) {
            _ = try await fixture.run("Lis le fichier")
        }
        #expect(fixture.client.state.withLock { $0.histories.isEmpty })
        #expect(fixture.agent.traceRecorder.events().compactMap(\.tool).isEmpty)
    }

    @Test func cancellationReleasesTheSharedLeaseBeforeTheNextRun() async throws {
        let fixture = try LocalProviderFixture([[.text("Début"), .pause, .text("Périmé")], [.text("Nouveau")]])
        defer { fixture.cleanup() }
        let (signal, ready) = AsyncStream<Void>.makeStream()
        let running = Task {
            for try await event in fixture.agent.stream(prompt: "Première demande") {
                if case .delta = event.kind { ready.yield(()); ready.finish() }
            }
            try Task.checkCancellation()
        }
        for await _ in signal { break }
        #expect(throws: MLXModelServiceError.generationInProgress) { try fixture.client.beginRun() }
        await #expect(throws: MLXModelServiceError.generationInProgress) {
            _ = try await fixture.run("Concurrence")
        }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        let settled = await fixture.agent.settledHistory()
        let history = try #require(settled)
        let lease = try fixture.client.beginRun()
        fixture.client.endRun(lease)
        let events = try await fixture.run("Deuxième demande", history: history)
        let text = events.compactMap { event -> String? in
            if case .delta(let value) = event.kind { value } else { nil }
        }.joined()
        #expect(text == "Nouveau")
        #expect(fixture.agent.traceRecorder.events().contains { $0.kind == .runCancelled })
    }

    private func toolResults(in history: [ChatMessage]) -> [String] {
        history.compactMap { message in
            if case .tool("read00001", "readFile", let content) = message { content } else { nil }
        }
    }
}
