// Created by Sébastien DAGUIN
import Foundation
import Testing
import NoctisAgent
@testable import Noctis

@Suite("Foundation Models Web routing through AgentLoop", .timeLimit(.minutes(1)))
struct FoundationModelsWebAgentTests {
    private let capability = "Tu peux faire une recherche sur le web ?"
    private let news = "Fais moi une review des news du jour en ia"
    private let followUp = "Tu peux utiliser web search ?"

    @Test func repairedConversationSearchesForNewsWithoutRepeatingItForACapabilityFollowUp() async throws {
        let fixture = FoundationModelsWebFixture()
        _ = try await fixture.run(capability)
        #expect(await fixture.search.queries.isEmpty)
        var history = try #require(fixture.agent.recoveryHistory)

        let newsEvents = try await fixture.run(news, history: history)
        #expect(await fixture.search.queries.count == 1)
        #expect(FoundationModelsWebFixture.text(in: newsEvents).contains("SOURCE_1"))
        history = try #require(fixture.agent.recoveryHistory)
        #expect(FoundationModelsWebFixture.results(in: history).count == 1)

        let followUpEvents = try await fixture.run(followUp, history: history)
        let queries = await fixture.search.queries
        #expect(queries.count == 1)
        #expect(queries.allSatisfy { $0.contains(news) })
        #expect(FoundationModelsWebFixture.text(in: followUpEvents) == "MODEL_RESPONSE: \(followUp)")
        history = try #require(fixture.agent.recoveryHistory)
        #expect(FoundationModelsWebFixture.results(in: history).count == 1)
        for prompt in [capability, news, followUp] { #expect(history.filter { $0 == .user(prompt) }.count == 1) }
        try history.validateForAgentHistory()

        let synthesis = fixture.client.requests.filter { $0.proposedToolCall == nil }
        #expect(synthesis.count == 3)
        let newsSynthesis = try #require(synthesis.dropFirst().first)
        #expect(FoundationModelsWebFixture.currentResults(in: newsSynthesis.history).count == 1)
        #expect(synthesis.last?.prompt == followUp)
        #expect(fixture.agent.traceRecorder.events().compactMap(\.tool).filter { $0.status == .executing }.count == 1)

        let general = try await fixture.run("Combien font 2 + 2 ?", history: history)
        #expect(await fixture.search.queries.count == 1)
        #expect(FoundationModelsWebFixture.text(in: general) == "MODEL_RESPONSE: Combien font 2 + 2 ?")
        #expect(fixture.client.requests.last?.prompt == "Combien font 2 + 2 ?")
    }

    @Test func capturedRefusalHistoryStillPermitsTheRequestedSearchOnTheNextTurn() async throws {
        let fixture = FoundationModelsWebFixture()
        let refusal = """
        Je n'ai pas accès aux données actuelles concernant les nouvelles liées à l'IA. \
        Veuillez vérifier des sources officielles ou des plateformes spécialisées pour obtenir des informations à jour.
        """
        let history: [ChatMessage] = [
            .user(capability), .assistant(AssistantMessage(content: "Oui, je peux faire une recherche sur le web.")),
            .user(news), .assistant(AssistantMessage(content: refusal))
        ]
        let events = try await fixture.run(followUp, history: history)
        #expect(await fixture.search.queries.count == 1)
        #expect(await fixture.search.queries.first?.contains(news) == true)
        #expect(FoundationModelsWebFixture.text(in: events).contains("SOURCE_1"))
        #expect(!FoundationModelsWebFixture.text(in: events).contains(refusal))
        #expect(fixture.client.requests.first?.prompt == followUp)
        #expect(fixture.client.requests.first?.history == history)
        #expect(fixture.client.requests.count == 2)
        let settled = try #require(fixture.agent.recoveryHistory)
        #expect(settled.filter { $0 == .user(followUp) }.count == 1)
        #expect(FoundationModelsWebFixture.results(in: settled).count == 1)
        try settled.validateForAgentHistory()
    }

    @Test func aFailedSearchIsReturnedOnceAndDoesNotTriggerAnAutomaticRetryLoop() async throws {
        let fixture = FoundationModelsWebFixture(.fails)
        let events = try await fixture.run(news)
        let results = events.compactMap { event -> ToolResult? in
            if case let .toolCallCompleted(_, _, result) = event.kind { result } else { nil }
        }
        #expect(await fixture.search.queries.count == 1)
        #expect(results.count == 1)
        #expect(results.first?.isError == true)
        #expect(fixture.client.requests.count == 2)
        #expect(fixture.client.requests.last?.proposedToolCall == nil)
        #expect(FoundationModelsWebFixture.text(in: events).contains("Échec de l’outil"))
        let history = try #require(fixture.agent.recoveryHistory)
        #expect(FoundationModelsWebFixture.results(in: history).count == 1)
        try history.validateForAgentHistory()
    }

    @Test func cancellingTheProposedSearchSettlesHistoryAndReleasesTheRunLease() async throws {
        let fixture = FoundationModelsWebFixture(.suspends)
        let running = Task {
            for try await _ in fixture.agent.stream(prompt: news) { }
            try Task.checkCancellation()
        }
        for await _ in fixture.search.started { break }
        #expect(throws: MLXModelServiceError.generationInProgress) { try fixture.client.beginRun() }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        let settled = await fixture.agent.settledHistory()
        let history = try #require(settled)
        try history.validateForAgentHistory()
        #expect(await fixture.search.queries.count == 1)
        #expect(await fixture.search.cancellations == 1)
        #expect(fixture.client.requests.count == 1)
        #expect(FoundationModelsWebFixture.results(in: history).count == 1)

        let lease = try fixture.client.beginRun()
        fixture.client.endRun(lease)
        let events = try await fixture.run("Bonjour", history: history)
        #expect(await fixture.search.queries.count == 1)
        #expect(FoundationModelsWebFixture.text(in: events) == "MODEL_RESPONSE: Bonjour")
        #expect(fixture.agent.traceRecorder.events().contains { $0.kind == .runCancelled })
    }

    @Test func authorizedWorkspaceRegistryDoesNotGiveTheBridgeNetworkTools() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try AuthorizedWorkspace(authorizing: directory)
        let registry = NoctisToolRegistry(workspace: ToolRegistry(workspace: workspace))
        let fixture = FoundationModelsWebFixture(registry: registry)
        _ = try await fixture.run(news)
        #expect(await fixture.search.queries.isEmpty)
        #expect(fixture.client.requests.count == 1)
        #expect(fixture.client.requests.allSatisfy { request in
            request.proposedToolCall == nil && !request.selection.tools.contains { $0.name == WebSearchTool.name }
        })
        #expect(fixture.agent.traceRecorder.events().compactMap(\.tool).isEmpty)
    }
}
