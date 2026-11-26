// Created by Sébastien DAGUIN
import Foundation
import MLXLMCommon
import Synchronization
import Testing
@testable import Noctis

@Suite("Response activity without model loading", .timeLimit(.minutes(1)))
struct AIResponseEventTests {
    @Test func existingTextProvidersRemainCompatibleWithoutInventedActivity() async throws {
        let service: any AIModelService = MockAIModelService(responses: [.chunks(["Bonjour", " !"])])
        let events = Mutex<[AIResponseEvent]>([])
        try await service.withResponseEvents(prompt: "Bonjour") { stream in
            for try await event in stream { events.withLock { $0.append(event) } }
        }
        #expect(events.withLock { $0 } == [.textDelta("Bonjour"), .textDelta(" !")])
    }

    @Test func modelEventsStaySeparateFromLegacyAnswerText() async throws {
        let expected: [AIResponseEvent] = [
            .reasoningDelta("Je vérifie les sources."),
            .toolStarted(id: "search001", name: "web_search", arguments: "{\"query\":\"Swift\"}"),
            .toolCompleted(id: "search001", name: "web_search", result: "Source trouvée", isError: false),
            .textDelta("Voici la réponse.")
        ]
        let service = MLXModelService(sessionFactory: { _ in ResponseFixtureSession(events: expected) })
        try await service.load()
        let events = Mutex<[AIResponseEvent]>([])
        try await service.withResponseEvents(prompt: "Recherche Swift") { stream in
            for try await event in stream { events.withLock { $0.append(event) } }
        }
        #expect(events.withLock { $0 } == expected)
        let text = Mutex("")
        try await service.withResponse(prompt: "Encore") { stream in
            for try await chunk in stream { text.withLock { $0 += chunk } }
        }
        #expect(text.withLock { $0 } == "Voici la réponse.")
    }

    @Test func agentActivityWaitsForFullArgumentsAndCorrelatesARealFailure() {
        var mapper = AIResponseEventMapper()
        let call = Noctis.ToolCall(id: "search001", name: "web_search", arguments: "{\"query\":\"Swift\"}")
        #expect(mapper.events(for: StreamEvent(kind: .toolCallStarted(name: call.name, id: call.id))).isEmpty)
        let iteration = StreamEvent(kind: .iterationCompleted(usage: nil, iteration: 1, history: [
            .user("Recherche Swift"), .assistant(AssistantMessage(content: "", toolCalls: [call]))
        ]))
        #expect(mapper.events(for: iteration) == [
            .toolStarted(id: call.id, name: call.name, arguments: call.arguments)
        ])
        #expect(mapper.events(for: iteration).isEmpty)
        #expect(mapper.events(for: StreamEvent(kind: .toolCallCompleted(
            id: call.id, name: call.name, result: .error("Outil indisponible")
        ))) == [.toolCompleted(id: call.id, name: call.name, result: "Outil indisponible", isError: true)])
        #expect(mapper.events(for: StreamEvent(kind: .reasoningDelta("Réflexion fournie"))) == [
            .reasoningDelta("Réflexion fournie")
        ])
    }

    @Test func internalFinishCallDoesNotLeaveAVisibleToolRunning() {
        var mapper = AIResponseEventMapper()
        let call = Noctis.ToolCall(id: "finish001", name: "finish", arguments: "{\"content\":\"Bonjour\"}")
        let event = StreamEvent(kind: .iterationCompleted(usage: nil, iteration: 1, history: [
            .assistant(AssistantMessage(content: "", toolCalls: [call]))
        ]))
        #expect(mapper.events(for: event).isEmpty)
    }

    @Test func macToolDispatchReportsTheActualArgumentsAndMatchingResult() async throws {
        let search = FoundationModelsWebFixtureSearch(.succeeds)
        let dispatcher = NoctisToolDispatcher(
            registry: NoctisToolRegistry(),
            web: WebToolDispatcher(searchService: search, pasgeService: ReliabilityPageService())
        )
        let call = MLXLMCommon.ToolCall(function: .init(name: "web_search", arguments: ["query": .string("Swift")]),
                                        id: "search001")
        let (stream, output) = AsyncThrowingStream<AIResponseEvent, Error>.makeStream()
        let result = try await MLXChatSession.dispatch(call, using: dispatcher, output: output)
        output.finish()
        var events: [AIResponseEvent] = []
        for try await event in stream { events.append(event) }
        #expect(await search.queries == ["Swift"])
        #expect(events == [
            .toolStarted(id: "search001", name: "web_search", arguments: "{\"query\":\"Swift\"}"),
            .toolCompleted(id: "search001", name: "web_search", result: result, isError: false)
        ])
    }

    @Test func cancelledMacToolNeverPublishesSuccessOrFailureAsAConfirmedResult() async throws {
        let search = FoundationModelsWebFixtureSearch(.suspends)
        let dispatcher = NoctisToolDispatcher(
            registry: NoctisToolRegistry(),
            web: WebToolDispatcher(searchService: search, pasgeService: ReliabilityPageService())
        )
        let call = MLXLMCommon.ToolCall(function: .init(name: "web_search", arguments: ["query": .string("Swift")]),
                                        id: "search001")
        let (stream, output) = AsyncThrowingStream<AIResponseEvent, Error>.makeStream()
        let dispatch = Task { try await MLXChatSession.dispatch(call, using: dispatcher, output: output) }
        for await _ in search.started { break }
        dispatch.cancel()
        await #expect(throws: CancellationError.self) { _ = try await dispatch.value }
        output.finish()
        var events: [AIResponseEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events == [.toolStarted(id: "search001", name: "web_search", arguments: "{\"query\":\"Swift\"}")])
        #expect(await search.cancellations == 1)
    }
}

private final class ResponseFixtureSession: ModelSession {
    let events: [AIResponseEvent]
    init(events: [AIResponseEvent]) { self.events = events }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AIResponseStream.map(streamResponseEvents(to: prompt), transform: AIResponseStream.text).stream
    }

    func streamResponseEvents(to prompt: String) -> AsyncThrowingStream<AIResponseEvent, Error> {
        AsyncThrowingStream { output in
            for event in events { output.yield(event) }
            output.finish()
        }
    }

    func synchronize() async {}
    func reset(history: [AIChatMessage]) async throws {}
}
