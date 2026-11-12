// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
import NoctisAgent
import Tokenizers
import os
@testable import Noctis

private enum ScriptStep: Sendable {
    case text(String)
    case call(String, String, [String: MLXLMCommon.JSONValue])
    case rejected
    case pause
}

private final class ScriptProbe: Sendable {
    struct State {
        var scripts: [[ScriptStep]]
        var histories: [[String]] = []
        var active = 0
        var maxActive = 0
    }
    let state: OSAllocatedUnfairLock<State>
    init(_ scripts: [[ScriptStep]]) { state = OSAllocatedUnfairLock(initialState: State(scripts: scripts)) }
}

private final class ScriptSession: StructuredModelSession {
    let probe: ScriptProbe
    var producer: Task<Void, Never>?
    init(_ probe: ScriptProbe) { self.probe = probe }
    func reset(history: [AIChatMessage]) async throws {}
    func synchronize() async { await producer?.value }
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamDetails(messages: [MLXLMCommon.Chat.Message], tools: [ToolSpec], instructions: String)
        -> AsyncThrowingStream<Generation, Error> {
        let roles = messages.map { $0.role.rawValue }
        let steps = probe.state.withLock { state in
            state.histories.append(roles)
            return state.scripts.isEmpty ? [] : state.scripts.removeFirst()
        }
        let probe = probe
        return AsyncThrowingStream { output in
            let task = Task {
                probe.state.withLock { state in
                    state.active += 1
                    state.maxActive = max(state.maxActive, state.active)
                }
                defer { probe.state.withLock { $0.active -= 1 } }
                do {
                    for step in steps {
                        try Task.checkCancellation()
                        switch step {
                        case .text(let text): output.yield(.chunk(text))
                        case let .call(name, id, arguments):
                            output.yield(.toolCall(MLXLMCommon.ToolCall(function: .init(name: name, arguments: arguments), id: id)))
                        case .rejected:
                            output.yield(.rejectedToolCall(.init(reason: .invalidArguments, format: .mistral,
                                                                 rawText: "SECRET_REJECTED_PAYLOAD")))
                        case .pause: try await Task.sleep(for: .seconds(30))
                        }
                    }
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
            producer = task
            output.onTermination = { _ in task.cancel() }
        }
    }
}

private struct OfflineTraceSearch: WebSearchService {
    func search(query: String) async throws -> [SearchResult] { [] }
}

private struct ReliabilityFixture {
    let agent: NoctisCLIAgent
    let client: NoctisLLMClient
    let probe: ScriptProbe
    let directory: URL

    init(_ scripts: [[ScriptStep]]) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("SECRET_FILE_BODY".utf8).write(to: directory.appendingPathComponent("example.swift"))
        let probe = ScriptProbe(scripts)
        self.probe = probe
        let worker = try await ModelSessionWorker.load(factory: { _ in ScriptSession(probe) }, progress: { _ in })
        client = NoctisLLMClient(worker: worker, systemPrompt: "SECRET_SYSTEM_PROMPT")
        let workspace = try AuthorizedWorkspace(authorizing: directory)
        agent = NoctisCLIAgent(client: client, registry: NoctisToolRegistry(workspace: ToolRegistry(workspace: workspace)),
                               web: WebToolDispatcher(searchService: OfflineTraceSearch(), pasgeService: HTTPWebPageService()))
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func run(_ prompt: String = "SECRET_USER_PROMPT", history: [ChatMessage] = []) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in agent.stream(prompt: prompt, history: history) { events.append(event) }
        return events
    }
}

@Suite("AgentLoop MLX reliability", .timeLimit(.minutes(1)))
struct AgentReliabilityTests {
    @Test func ordinaryConversationTerminatesOnceAndDoesNotConfirmInventedResults() async throws {
        let fixture = try await ReliabilityFixture([[.text("J’ai lu invented.swift")], [.text("Deuxième réponse")]])
        defer { fixture.cleanup() }
        let events = try await fixture.run()
        #expect(fixture.probe.state.withLock { $0.histories.count } == 1)
        #expect(events.contains { if case .finished = $0.kind { true } else { false } })
        #expect(fixture.agent.traceRecorder.events().allSatisfy { $0.tool == nil })
        let history = try #require(fixture.agent.recoveryHistory)
        _ = try await fixture.run("Suite", history: history)
        #expect(fixture.probe.state.withLock { $0.histories.last } == ["user", "assistant", "user"])
        #expect(Set(fixture.agent.traceRecorder.events().map(\.runID)).count == 2)
    }

    @Test func toolExecutionHasOneCorrelatedObservedResultAndPrivateTrace() async throws {
        let fixture = try await ReliabilityFixture([
            [.call("readFile", "read00001", ["path": .string("example.swift")])], [.text("Lecture terminée")],
            [.call("listFiles", "list00002", ["path": .string(".")])], [.text("Liste terminée")]
        ])
        defer { fixture.cleanup() }
        let events = try await fixture.run()
        let completed = events.filter { if case .toolCallCompleted = $0.kind { true } else { false } }
        #expect(completed.count == 1)
        let trace = fixture.agent.traceRecorder.events()
        #expect(trace.compactMap(\.tool).map(\.status) == [.requested, .validated, .executing, .succeeded])
        #expect(trace.compactMap(\.tool).allSatisfy { $0.callID == "read00001" })
        #expect(trace.compactMap(\.tool).last?.result == .observedSuccess)
        #expect(trace.compactMap(\.tool).last?.duration != nil)
        #expect(trace.allSatisfy { $0.diagnosticCode == nil })
        let description = String(reflecting: trace)
        for secret in ["SECRET_FILE_BODY", "SECRET_USER_PROMPT", "SECRET_SYSTEM_PROMPT", "example.swift"] {
            #expect(!description.contains(secret))
        }
        let history = try #require(fixture.agent.recoveryHistory)
        _ = try await fixture.run("Encore", history: history)
        let histories = fixture.probe.state.withLock { $0.histories }
        #expect(histories[1] == ["user", "assistant", "tool"])
        #expect(histories[2] == ["user", "assistant", "tool", "assistant", "user"])
        #expect(histories[3] == ["user", "assistant", "tool", "assistant", "user", "assistant", "tool"])
        #expect(fixture.agent.traceRecorder.events().compactMap(\.tool).filter { $0.status == .succeeded }.count == 2)
        fixture.agent.endSession()
        #expect(fixture.agent.traceRecorder.events().last?.kind == .sessionEnded)
    }

    @Test func invalidCallIsNeverRepairedOrDispatched() async throws {
        let fixture = try await ReliabilityFixture([[.rejected], [.text("Reprise")]])
        defer { fixture.cleanup() }
        await #expect(throws: Noctis.AgentError.invalidToolCall) { _ = try await fixture.run() }
        let traces = fixture.agent.traceRecorder.events()
        #expect(traces.contains { $0.kind == .toolRejected && $0.reason == .rejected(.invalidArguments) })
        #expect(!traces.contains { $0.tool?.status == .executing })
        #expect(!String(reflecting: traces).contains("SECRET_REJECTED_PAYLOAD"))
        let history = try #require(fixture.agent.recoveryHistory)
        _ = try await fixture.run("Reprise", history: history)
        #expect(fixture.probe.state.withLock { $0.histories.last } == ["user", "assistant", "user"])
    }

    @Test func duplicateCallIDCannotDispatchTwice() async throws {
        let fixture = try await ReliabilityFixture([
            [.call("readFile", "read00001", ["path": .string("example.swift")])],
            [.call("readFile", "read00001", ["path": .string("example.swift")])]
        ])
        defer { fixture.cleanup() }
        await #expect(throws: Noctis.AgentError.invalidToolCall) { _ = try await fixture.run() }
        #expect(fixture.agent.traceRecorder.events().compactMap(\.tool).filter { $0.status == .executing }.count == 1)
        let history = try #require(fixture.agent.recoveryHistory)
        #expect(try NoctisLLMClient.messages(history).map(\.role) == [.user, .assistant, .tool, .assistant])
    }

    @Test func permissionRefusalIsNotReportedAsSuccess() async throws {
        let fixture = try await ReliabilityFixture([
            [.call("readFile", "deny00001", ["path": .string("../private")])], [.text("Accès refusé")]
        ])
        defer { fixture.cleanup() }
        let events = try await fixture.run()
        #expect(events.contains { event in
            if case .toolCallCompleted(_, _, let result) = event.kind { return result.isError }
            return false
        })
        let tool = try #require(fixture.agent.traceRecorder.events().compactMap(\.tool).last)
        #expect(tool.status == .refused)
        #expect(tool.reason == .permissionDenied)
        #expect(tool.result == .notObserved)
    }

    @Test func badIDsAndArgumentTypesNeverReachDispatcher() async throws {
        for step in [ScriptStep.call("readFile", "invalid-id", ["path": .string("example.swift")]),
                     .call("readFile", "bad000001", ["path": .int(42)]),
                     .call("readFile", "bad000002", ["extra": .string("example.swift")])] {
            let fixture = try await ReliabilityFixture([[step], [.text("Refus")]])
            defer { fixture.cleanup() }
            do { _ = try await fixture.run() } catch {}
            #expect(!fixture.agent.traceRecorder.events().compactMap(\.tool).contains { $0.status == .executing })
        }
    }

    @Test func cancellationAndSuccessiveGenerationsStayIsolated() async throws {
        let fixture = try await ReliabilityFixture([[.text("OLD"), .pause, .text("STALE")], [.text("NEW")]])
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
        // Wait for the cancelled stream's owner to publish its recovery snapshot.
        for _ in 0..<100 where fixture.agent.recoveryHistory == nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        let history = try #require(fixture.agent.recoveryHistory)
        let events = try await fixture.run("Suite", history: history)
        let text = events.compactMap { event -> String? in if case .delta(let text) = event.kind { text } else { nil } }.joined()
        #expect(text == "NEW")
        #expect(fixture.probe.state.withLock { $0.maxActive } == 1)
        #expect(fixture.agent.traceRecorder.events().contains { $0.kind == .runCancelled })
    }

    @Test func recorderIsBoundedAndDiagnosticsRemainMetadataOnly() {
        let recorder = AgentTraceRecorder(capacity: 3)
        let scope = AgentTraceScope(recorder: recorder, runID: RunID())
        for _ in 0..<10 { scope.record(.generationStarted) }
        #expect(recorder.events().count == 3)
        recorder.diagnosticsEnabled = true
        scope.record(.generationFailed, reason: .template)
        #expect(recorder.events().last?.kind == .templateFailed)
        #expect(recorder.events().last?.diagnosticCode == "templateFailed")
        scope.record(.generationFailed, reason: .serialization)
        #expect(recorder.events().last?.kind == .serializationFailed)
        recorder.clear()
        #expect(recorder.events().isEmpty)
    }

    @Test func malformedJSONIsRejectedAndStringSchemasAreNotEmptyEnums() throws {
        #expect(throws: Noctis.AgentError.invalidArguments) { try NoctisLLMClient.decodedArguments("invalid") }
        #expect(throws: Noctis.AgentError.invalidArguments) { try NoctisLLMClient.decodedArguments("[]") }
        let spec = NoctisLLMClient.tool(ToolDefinition(name: "test", description: "", parametersSchema: .string()))
        let function = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        #expect(parameters["enum"] == nil)
    }

    @Test func cachedMinistralTemplateAcceptsCompleteMultiTurnToolsAndRejectsRepeatedAssistant() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".cache/huggingface/hub/models--mlx-community--Ministral-3-14B-Instruct-2512-4bit/snapshots")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
              let folder = folders.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path) })
        else { return }
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        let messages: [ChatMessage] = [
            .user("Bonjour"), .assistant(AssistantMessage(content: "Bonsoir")), .user("Lis"),
            .assistant(AssistantMessage(content: "", toolCalls: [ToolCall(id: "read00001", name: "readFile", arguments: "{\"path\":\"a\"}")])),
            .tool(id: "read00001", name: "readFile", content: "observed"),
            .assistant(AssistantMessage(content: "Lu")), .user("Suite")
        ]
        let generator = DefaultMessageGenerator()
        let mlx = try NoctisLLMClient.messages(messages)
        let tokens = try tokenizer.applyChatTemplate(messages: mlx.map { generator.generate(message: $0) })
        #expect(!tokens.isEmpty)
        let invalid = Array(mlx.prefix(2)) + [.assistant("Encore")]
        #expect(throws: (any Error).self) {
            try tokenizer.applyChatTemplate(messages: invalid.map { generator.generate(message: $0) })
        }
    }
}
