// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
import NoctisAgent
import Tokenizers
import os
@testable import Noctis

extension AgentReliabilityTests {
    @Test func contentChunksDisplayAndRememberTheAnswerOnce() async throws {
        for prefix in ["", "Par", "Paris"] {
            let fixture = try await ReliabilityFixture([
                [.text(prefix), .text(String("Paris".dropFirst(prefix.count)))], [.text("Suite")]
            ])
            defer { fixture.cleanup() }
            let events = try await fixture.run("Capitale ?")
            let displayed = events.compactMap { event -> String? in
                if case .delta(let text) = event.kind { return text }
                return nil
            }.joined()
            #expect(displayed == "Paris")
            let history = try #require(fixture.agent.recoveryHistory)
            #expect(history == [.user("Capitale ?"), .assistant(AssistantMessage(content: "Paris"))])
            _ = try await fixture.run("Encore", history: history)
            #expect(fixture.probe.state.withLock { $0.histories.last } == ["user", "assistant", "user"])
        }
    }

    @Test func replacingWorkspaceEndsEveryIssuedAgent() async throws {
        let probe = ScriptProbe([[.text("Début"), .pause], [.text("OK")]])
        let model = MLXModelService(sessionFactory: { _ in ScriptSession(probe) })
        try await model.load()
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await model.authorizeWorkspace(AuthorizedWorkspace(authorizing: directory))
        let first = try await model.makeNoctisCLIAgent()
        let second = try await model.makeNoctisCLIAgent()
        var running = first.stream(prompt: "En cours").makeAsyncIterator()
        while let event = try await running.next() {
            if case .delta = event.kind { break }
        }
        try await model.authorizeWorkspace(nil)
        #expect(probe.state.withLock { $0.active } == 0)
        #expect(first.traceRecorder.events().contains { $0.kind == .runCancelled })
        for old in [first, second] {
            await #expect(throws: MLXModelServiceError.sessionInvalidated) {
                for try await _ in old.stream(prompt: "Bonjour") {}
            }
        }
        let current = try await model.makeNoctisCLIAgent()
        for try await _ in current.stream(prompt: "Bonjour") {}
        #expect(probe.state.withLock { $0.histories.count } == 2)
    }

    @Test func cancellationAndSuccessiveGenerationsStayIsolated() async throws {
        let fixture = try await ReliabilityFixture([
            [.call("readFile", "read00001", ["path": .string("example.swift")])],
            [.text("OLD"), .pause, .text("STALE")], [.text("NEW")]
        ])
        defer { fixture.cleanup() }
        let (signal, ready) = AsyncStream<Void>.makeStream()
        let first = Task {
            for try await event in fixture.agent.stream(prompt: "Premier") {
                if case .delta = event.kind { ready.yield(()); ready.finish() }
            }
            try Task.checkCancellation()
        }
        for await _ in signal { break }
        await #expect(throws: MLXModelServiceError.generationInProgress) { _ = try await fixture.run("Concurrent") }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let settled = await fixture.agent.settledHistory()
        let history = try #require(settled)
        let results = history.compactMap { message -> String? in
            guard case .tool("read00001", "readFile", let content) = message else { return nil }
            return content
        }
        #expect(results.count == 1)
        #expect(results.first?.contains("SECRET_FILE_BODY") == true)
        guard case .assistant(let interrupted) = history.last else {
            Issue.record("Expected the interrupted assistant turn")
            return
        }
        #expect(interrupted.content.hasPrefix("OLD"))
        let events = try await fixture.run("Suite", history: history)
        let text = events.compactMap { event -> String? in
            if case .delta(let text) = event.kind { text } else { nil }
        }.joined()
        #expect(text == "NEW")
        #expect(fixture.probe.state.withLock { $0.maxActive } == 1)
        #expect(fixture.agent.traceRecorder.events().contains { $0.kind == .runCancelled })
    }
}
