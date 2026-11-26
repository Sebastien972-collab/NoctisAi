// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
import NoctisAgent
@testable import Noctis

@Suite("MLX 3.33 stream compatibility without model loading", .timeLimit(.minutes(1)))
struct MLXStreamCompatibilityTests {
    @Test func bonsaiWebSearchPreservesTheParserAssignedIDThroughDispatchAndReplay() async throws {
        let parser = ToolCallProcessor(format: .qwen35, tools: NoctisToolRegistry().schemas,
                                       toolCallPolicy: .init(recovery: .disabled, validation: .strict))
        _ = parser.processChunk("""
            <tool_call>
            <function=web_search>
            <parameter=query>
            Swift
            </parameter>
            </function>
            </tool_call>
            """)
        parser.processEOS()
        let call = try #require(parser.toolCalls.first)
        let id = try #require(call.id)
        #expect(id.hasPrefix("call_"))
        let search = FoundationModelsWebFixtureSearch(.succeeds)
        let fixture = try await ReliabilityFixture([
            [.generation(.toolCall(call))], [.text("Source trouvée")]
        ], workspaceEnabled: false, searchService: search)
        defer { fixture.cleanup() }
        let events = try await fixture.run("Recherche Swift")
        #expect(await search.queries == ["Swift"])
        #expect(events.contains {
            if case let .toolCallCompleted(callID, name, result) = $0.kind {
                return callID == id && name == "web_search" && result.content.contains("SOURCE_1")
            }
            return false
        })
        let history = try #require(fixture.agent.recoveryHistory)
        let replay = try NoctisLLMClient.messages(history).map { DefaultMessageGenerator().generate(message: $0) }
        let assistant = replay.first { $0["role"] as? String == "assistant" }
        let calls = assistant?["tool_calls"] as? [[String: any Sendable]]
        #expect(calls?.first?["id"] as? String == id)
        let result = replay.first { $0["role"] as? String == "tool" }
        #expect(result?["tool_call_id"] as? String == id)
    }

    @Test(arguments: ["call_", "call_0123456789abcdef0123456789abcdeg",
                      "call_0123456789abcdef0123456789abcdef0", "bad id   "])
    func rejectsMalformedCallIDs(_ id: String) {
        #expect(!NoctisLLMClient.isValidCallID(id))
    }

    @Test func reasoningAndSteeringDoNotBecomeAssistantContent() async throws {
        let client = try await makeClient(events: [
            .reasoning("PRIVATE_REASONING"), .chunk("Réponse"), completion(.steered),
            .steering(.applied([UUID()])), .chunk(" finale"), completion(.stop)
        ])
        var deltas: [StreamDelta] = []
        for try await delta in client.stream(messages: [.user("Bonjour")], tools: [], requestContext: nil) {
            deltas.append(delta)
        }
        #expect(deltas.compactMap { delta -> String? in
            if case .content(let text) = delta { text } else { nil }
        }.joined() == "Réponse finale")
        #expect(deltas.compactMap { delta -> String? in
            if case .reasoning(let text) = delta { text } else { nil }
        } == ["PRIVATE_REASONING"])
        #expect(deltas.filter { if case .finished = $0 { true } else { false } }.count == 1)
        #expect(deltas.last == .streamClosed(terminalMarkerSeen: true))
    }

    @Test func reasoningAloneCannotCompleteAnAgentTurn() async throws {
        let client = try await makeClient(events: [.reasoning("PRIVATE_REASONING"), completion(.stop)])
        await #expect(throws: Noctis.AgentError.invalidToolCall) {
            _ = try await client.generate(messages: [.user("Bonjour")], tools: [],
                                          responseFormat: nil, requestContext: nil)
        }
    }

    @Test(arguments: [GenerateStopReason.cancelled, .interrupted])
    func incompleteResponsesNeverEmitCompletion(stopReason: GenerateStopReason) async throws {
        let client = try await makeClient(events: [.chunk("Partiel"), completion(stopReason)])
        var deltas: [StreamDelta] = []
        await #expect(throws: CancellationError.self) {
            for try await delta in client.stream(messages: [.user("Bonjour")], tools: [], requestContext: nil) {
                deltas.append(delta)
            }
        }
        #expect(deltas == [.content("Partiel")])
        let lease = try client.beginRun()
        client.endRun(lease)
    }

    @Test func generationLimitStillReportsAnIncompleteAnswer() async throws {
        let client = try await makeClient(events: [.chunk("Partiel"), completion(.length)])
        await #expect(throws: MLXModelServiceError.responseLimit) {
            _ = try await client.generate(messages: [.user("Bonjour")], tools: [],
                                          responseFormat: nil, requestContext: nil)
        }
    }

    @Test func workspaceAdapterKeepsOnlyAnswerContent() async throws {
        let response = try await collect([
            .reasoning("PRIVATE_REASONING"), .chunk("Réponse"), completion(.steered),
            .steering(.applied([UUID()])), .chunk(" finale"), completion(.stop)
        ])
        #expect(response.text == "Réponse finale")
        #expect(response.calls.isEmpty)
    }

    @Test(arguments: [GenerateStopReason.cancelled, .interrupted])
    func workspaceAdapterRejectsIncompleteResponses(stopReason: GenerateStopReason) async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await collect([.chunk("Partiel"), completion(stopReason)])
        }
    }

    private func makeClient(events: [Generation]) async throws -> NoctisLLMClient {
        let probe = ScriptProbe([events.map(ScriptStep.generation)])
        let worker = try await ModelSessionWorker.load(
            factory: { _ in ScriptSession(probe) }, progress: { _ in }
        )
        return NoctisLLMClient(worker: worker, systemPrompt: "Test")
    }

    private func collect(_ events: [Generation]) async throws -> AgentResponse {
        let stream = AsyncThrowingStream<Generation, Error> { output in
            for event in events { output.yield(event) }
            output.finish()
        }
        return try await MLXModelService.collectAgentResponse(
            stream, cancellation: GenerationCancellation(), limits: AgentLimits()
        )
    }

    private func completion(_ reason: GenerateStopReason) -> Generation {
        .info(GenerateCompletionInfo(promptTokenCount: 2, generationTokenCount: 3,
                                     promptTime: 0, generationTime: 0, stopReason: reason))
    }
}
