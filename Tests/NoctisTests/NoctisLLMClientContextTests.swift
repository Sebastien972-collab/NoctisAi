// Created by Sébastien DAGUIN

import Foundation
import Testing
@testable import Noctis

@Suite("MLX context recovery", .timeLimit(.minutes(1)))
struct NoctisLLMClientContextTests {
    @Test func webOverflowRetriesInferenceWithoutRepeatingToolsOrChangingSavedHistory() async throws {
        let search = ContextRecoverySearch()
        let pages = ContextRecoveryPages()
        let fixture = try await ReliabilityFixture([
            [.call("web_search", "search001", ["query": .string("Swift aujourd'hui")])],
            [.call("web_open", "page00001", ["url": .string(ContextRecoverySearch.url)])],
            [.contextLimit], [.text("Voici la synthèse avec sa source.")]
        ], workspaceEnabled: false, profile: .gptOSS, searchService: search, pageService: pages)
        defer { fixture.cleanup() }

        let events = try await fixture.run("Les actualités Swift")
        #expect(await search.calls == 1)
        #expect(await pages.calls == 1)
        #expect(fixture.probe.state.withLock { $0.histories.count } == 4)
        #expect(fixture.probe.state.withLock { $0.maxActive } == 1)
        #expect(events.filter { if case .toolCallCompleted = $0.kind { true } else { false } }.count == 2)
        #expect(events.compactMap { if case .delta(let text) = $0.kind { text } else { nil } }.joined()
                == "Voici la synthèse avec sa source.")
        let history = try #require(fixture.agent.recoveryHistory)
        let results = history.compactMap { message -> String? in
            if case .tool(_, _, let content) = message { content } else { nil }
        }
        try #require(results.count == 2)
        let searchEnvelope = try #require(JSONSerialization.jsonObject(with: Data(results[0].utf8)) as? [String: Any])
        let hits = try #require(searchEnvelope["results"] as? [[String: Any]])
        #expect(hits.first?["url"] as? String == ContextRecoverySearch.url)
        #expect(hits.first?["description"] as? String == String(ContextRecoverySearch.excerpt.prefix(2_000)))
        let pageEnvelope = try #require(JSONSerialization.jsonObject(with: Data(results[1].utf8)) as? [String: Any])
        #expect(pageEnvelope["url"] as? String == ContextRecoverySearch.url)
        #expect(pageEnvelope["content"] as? String == String(ContextRecoveryPages.excerpt.prefix(3_000)))
        #expect(history.first == .user("Les actualités Swift"))
        #expect(history.last == .assistant(AssistantMessage(content: "Voici la synthèse avec sa source.")))
    }

    @Test func irreducibleContextFailsOnceWithoutEmptyRetries() async throws {
        let fixture = try await ReliabilityFixture([[.contextLimit]], workspaceEnabled: false)
        defer { fixture.cleanup() }
        await #expect(throws: MLXModelServiceError.contextLimit) {
            _ = try await fixture.client.generate(messages: [.user("Question intacte")], tools: [],
                                                  responseFormat: nil, requestContext: nil)
        }
        #expect(fixture.probe.state.withLock { $0.histories.count } == 1)
        let lease = try fixture.client.beginRun()
        fixture.client.endRun(lease)
    }

    @Test func persistentOverflowHasABoundedNumberOfAttempts() async throws {
        let fixture = try await ReliabilityFixture(Array(repeating: [.contextLimit], count: 5),
                                                   workspaceEnabled: false)
        defer { fixture.cleanup() }
        await #expect(throws: MLXModelServiceError.contextLimit) {
            _ = try await fixture.client.generate(messages: try Self.largeHistory(), tools: [],
                                                  responseFormat: nil, requestContext: nil)
        }
        #expect(fixture.probe.state.withLock { $0.histories.count } == 4)
        #expect(fixture.probe.state.withLock { $0.maxActive } == 1)
    }

    @Test(arguments: ["Début de réponse", " "])
    func contextFailureAfterAnyContentIsNeverRetried(content: String) async throws {
        let fixture = try await ReliabilityFixture([[.text(content), .contextLimit], [.text("À ne pas rejouer")]],
                                                   workspaceEnabled: false)
        defer { fixture.cleanup() }
        var displayed = ""
        await #expect(throws: MLXModelServiceError.contextLimit) {
            for try await delta in fixture.client.stream(messages: try Self.largeHistory(),
                                                         tools: [], requestContext: nil) {
                if case .content(let text) = delta { displayed += text }
            }
        }
        #expect(displayed == content)
        #expect(fixture.probe.state.withLock { $0.histories.count } == 1)
    }

    @Test func invalidToolCallsAreNotRetriedAsContextFailures() async throws {
        let fixture = try await ReliabilityFixture([[.rejected], [.text("À ne pas rejouer")]],
                                                   workspaceEnabled: false)
        defer { fixture.cleanup() }
        await #expect(throws: Noctis.AgentError.invalidToolCall) {
            _ = try await fixture.client.generate(messages: try Self.largeHistory(), tools: [],
                                                  responseFormat: nil, requestContext: nil)
        }
        #expect(fixture.probe.state.withLock { $0.histories.count } == 1)
    }

    @Test func cancellationDuringARetryStillJoinsTheProducer() async throws {
        let search = ContextRecoverySearch()
        let fixture = try await ReliabilityFixture([
            [.call("web_search", "search001", ["query": .string("Swift")])],
            [.contextLimit], [.text("Reprise"), .pause]
        ], workspaceEnabled: false, searchService: search)
        defer { fixture.cleanup() }
        let (signal, ready) = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.finish() }
            for try await event in fixture.agent.stream(prompt: "Recherche Swift") {
                if case .delta = event.kind { ready.yield(()); ready.finish() }
            }
            try Task.checkCancellation()
        }
        for await _ in signal { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        _ = await fixture.agent.settledHistory()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !fixture.agent.traceRecorder.events().contains(where: { $0.kind == .generationCancelled })
                && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.agent.traceRecorder.events().contains { $0.kind == .generationCancelled })
        #expect(await search.calls == 1)
        #expect(fixture.probe.state.withLock { $0.histories.count } == 3)
        #expect(fixture.probe.state.withLock { $0.active } == 0)
        #expect(fixture.probe.state.withLock { $0.maxActive } == 1)
    }

    private static func largeHistory() throws -> [ChatMessage] {
        let object: [String: Any] = [
            "trust": "UNTRUSTED_EXTERNAL_DATA", "status": "retrieved",
            "url": ContextRecoverySearch.url, "title": "Source Swift",
            "content": ContextRecoveryPages.excerpt, "isTruncated": true
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let payload = try #require(String(data: data, encoding: .utf8))
        return [
            .user("Avant"), .assistant(AssistantMessage(content: "Réponse précédente")),
            .user("Synthétise ces sources"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "page00001", name: "web_open",
                         arguments: "{\"url\":\"https://www.swift.org/source\"}")
            ])),
            .tool(id: "page00001", name: "web_open", content: payload)
        ]
    }
}

private actor ContextRecoverySearch: WebSearchService {
    static let url = "https://www.swift.org/source"
    static let excerpt = String(repeating: "Source vérifiée. ", count: 220)
    private(set) var calls = 0

    func search(query: String) async throws -> [SearchResult] {
        calls += 1
        let url = try #require(URL(string: Self.url))
        return [SearchResult(title: "Source Swift", url: url, content: Self.excerpt)]
    }
}

private actor ContextRecoveryPages: WebPageService {
    static let excerpt = String(repeating: "Article vérifié. ", count: 220)
    private(set) var calls = 0

    func open(url: URL) async throws -> WebPage {
        calls += 1
        return WebPage(url: url.absoluteString, title: "Page Swift", content: Self.excerpt, isTruncated: false)
    }
}
