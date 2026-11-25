// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
import NoctisAgent
@testable import Noctis

@Suite("MLX 3.33 stream compatibility without model loading", .timeLimit(.minutes(1)))
struct MLXStreamCompatibilityTests {
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
        #expect(!deltas.contains { if case .reasoning = $0 { true } else { false } })
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
