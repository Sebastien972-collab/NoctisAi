// Created by Sébastien DAGUIN
import Foundation
import Testing
@testable import Noctis

@Suite("iOS local model selection")
struct IOSModelSelectionTests {
    @Test func automaticPrefersTheAvailableAppleModel() throws {
        let selected = try IOSModelConfiguration.select(preference: .automatic, availability: .available)
        #expect(selected.provider == .foundationModels)
        #expect(selected.fallbackReason == nil)
    }

    @Test(arguments: [
        IOSFoundationModelsAvailability.requiresIOS26, .frameworkUnavailable, .appleIntelligenceNotEnabled,
        .deviceNotEligible, .modelNotReady, .unknown
    ])
    func unavailableAppleModelHasAnExplicitLocalFallback(availability: IOSFoundationModelsAvailability) throws {
        let selected = try IOSModelConfiguration.select(preference: .automatic, availability: availability)
        #expect(selected.provider == .mlx)
        #expect(selected.foundationModelsAvailability == availability)
        #expect(selected.fallbackReason == availability.reason)
        #expect(selected.fallbackReason != nil)
        #expect(throws: IOSModelServiceError.foundationModelsUnavailable(availability)) {
            try IOSModelConfiguration.select(preference: .foundationModels, availability: availability)
        }
    }

    @Test func explicitMLXRemainsMLXEvenWhenAppleIsAvailable() throws {
        let selected = try IOSModelConfiguration.select(preference: .mlx, availability: .available)
        #expect(selected.provider == .mlx)
        #expect(selected.fallbackReason == nil)
        #expect(IOSModelConfiguration.mlxModelID == "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit")
        #expect(NoctisConfiguration.modelID == IOSModelConfiguration.mlxModelID)
    }

    @Test func compactedProviderContextDoesNotDeleteHostHistory() {
        let history = (0..<10).flatMap { index -> [ChatMessage] in
            [.user("Question \(index)"), .assistant(AssistantMessage(content: "Réponse \(index)"))]
        }
        let final = ChatMessage.assistant(AssistantMessage(content: "Réponse suivante"))
        let bounded = Array((history + [.user("Suite")]).suffix(12)) + [final]
        var transcript = IOSConversationTranscript(history: history, prompt: "Suite")
        transcript.observe(StreamEvent(kind: .iterationCompleted(usage: nil, iteration: 1, history: bounded)))
        transcript.observe(StreamEvent(kind: .finished(
            tokenUsage: TokenUsageTotals(), content: "Réponse suivante", reason: .completed, history: bounded
        )))
        #expect(transcript.settled(error: nil) == history + [.user("Suite"), final])
    }

    @Test func interruptedTranscriptKeepsCommittedToolResultsOnce() throws {
        let call = ToolCall(id: "read00001", name: "readFile", arguments: "{\"path\":\"file.swift\"}")
        let assistant = ChatMessage.assistant(AssistantMessage(content: "", toolCalls: [call]))
        var transcript = IOSConversationTranscript(history: [], prompt: "Lis ce fichier")
        transcript.observe(StreamEvent(kind: .iterationCompleted(
            usage: nil, iteration: 1, history: [.user("Lis ce fichier"), assistant]
        )))
        transcript.observe(StreamEvent(kind: .toolCallCompleted(
            id: call.id, name: call.name, result: ToolResult(content: "Contenu confirmé")
        )))
        let history = transcript.settled(error: CancellationError())
        let results = history.filter { if case .tool = $0 { true } else { false } }
        #expect(results == [.tool(id: call.id, name: call.name, content: "Contenu confirmé")])
        try history.validateForAgentHistory()
    }
}

#if os(iOS)
import os

@Suite("iOS model service lifecycle", .timeLimit(.minutes(1)))
struct IOSModelServiceTests {
    @Test func automaticAppleUsesTheHostAgentAndPreservesConsecutiveTurns() async throws {
        let fixture = IOSServiceFixture(replies: [.answer("Première réponse"), .answer("Seconde réponse")])
        try await fixture.service.load { fixture.probe.record($0) }
        #expect(await fixture.service.selection?.provider == .foundationModels)
        #expect(try await fixture.read("Bonjour") == "Première réponse")
        #expect(try await fixture.read("Suite") == "Seconde réponse")
        #expect(fixture.probe.snapshot.mlxLoads == 0)
        #expect(fixture.probe.snapshot.phases == [.loading, .ready])
        #expect(fixture.probe.snapshot.histories.last == [
            .user("Bonjour"), .assistant(AssistantMessage(content: "Première réponse")), .user("Suite")
        ])
    }

    @Test func unavailableExplicitAppleDoesNotLoadMLX() async throws {
        let fixture = IOSServiceFixture(preference: .foundationModels, availability: .deviceNotEligible)
        await #expect(throws: IOSModelServiceError.foundationModelsUnavailable(.deviceNotEligible)) {
            try await fixture.service.load()
        }
        #expect(fixture.probe.snapshot.mlxLoads == 0)
        #expect(await fixture.service.foundationModelsAvailability == .deviceNotEligible)
    }

    @Test func MLXProgressIsDeduplicatedAndReadyIsEmittedOnce() async throws {
        let fixture = IOSServiceFixture(preference: .mlx)
        try await fixture.service.load { fixture.probe.record($0) }
        #expect(await fixture.service.loadState == .loaded)
        #expect(await fixture.service.selection?.provider == .mlx)
        #expect(fixture.probe.snapshot.mlxLoads == 1)
        #expect(fixture.probe.snapshot.phases == [.loading, .downloading, .loading, .ready])
    }

    @Test func resettingAndRevokingInvalidatePreviouslyIssuedAgentsAndClients() async throws {
        let fixture = IOSServiceFixture()
        try await fixture.service.load()
        let agent = try await fixture.service.makeNoctisCLIAgent()
        let client = try await fixture.service.makeLLMClient()
        try await fixture.service.authorizeWorkspace(nil)
        await #expect(throws: MLXModelServiceError.sessionInvalidated) {
            for try await _ in agent.stream(prompt: "Ancienne session") {}
        }
        await #expect(throws: MLXModelServiceError.sessionInvalidated) {
            for try await _ in client.stream(messages: [.user("Ancien client")], tools: []) {}
        }
        #expect(fixture.probe.snapshot.histories.isEmpty)
        #expect(await fixture.service.conversationHistory.isEmpty)
    }

    @Test func returningEarlyCancelsBeforeTheNextResponse() async throws {
        let fixture = IOSServiceFixture(replies: [.pause("Début"), .answer("Nouveau")])
        try await fixture.service.load()
        try await fixture.service.withResponse(prompt: "Premier") { stream in
            for try await _ in stream { break }
        }
        #expect(try await fixture.read("Deuxième") == "Nouveau")
        let history = await fixture.service.conversationHistory
        #expect(history.last == .assistant(AssistantMessage(content: "Nouveau")))
        #expect(fixture.probe.snapshot.histories.count == 2)
    }

    @Test func activityEventsKeepReasoningSeparateAndPreserveTheConversation() async throws {
        let fixture = IOSServiceFixture(replies: [.reasonedAnswer("Réflexion", "Réponse"), .answer("Suite")])
        try await fixture.service.load()
        let events = OSAllocatedUnfairLock(initialState: [AIResponseEvent]())
        try await fixture.service.withResponseEvents(prompt: "Question") { stream in
            for try await event in stream { events.withLock { $0.append(event) } }
        }
        #expect(events.withLock { $0 } == [.reasoningDelta("Réflexion"), .textDelta("Réponse")])
        #expect(try await fixture.read("Encore") == "Suite")
        let history = await fixture.service.conversationHistory
        #expect(history.filter { if case .user = $0 { true } else { false } }.count == 2)
    }

    @Test func returningDuringReasoningSettlesBeforeTheNextResponse() async throws {
        let fixture = IOSServiceFixture(replies: [.reasoningPause("Réflexion"), .answer("Nouveau")])
        try await fixture.service.load()
        try await fixture.service.withResponseEvents(prompt: "Question") { stream in
            for try await event in stream {
                #expect(event == .reasoningDelta("Réflexion"))
                break
            }
        }
        #expect(try await fixture.read("Encore") == "Nouveau")
        #expect(fixture.probe.snapshot.histories.count == 2)
    }

    @Test func inferenceFailureNeverSwitchesProviders() async throws {
        let fixture = IOSServiceFixture(replies: [.failure])
        try await fixture.service.load()
        await #expect(throws: IOSModelServiceError.foundationModelsUnavailable(.modelNotReady)) {
            _ = try await fixture.read("Bonjour")
        }
        #expect(await fixture.service.selection?.provider == .foundationModels)
        #expect(fixture.probe.snapshot.mlxLoads == 0)
    }
}

private struct IOSServiceFixture: Sendable {
    let probe: IOSServiceProbe
    let service: IOSModelService

    init(preference: IOSModelPreference = .automatic,
         availability: IOSFoundationModelsAvailability = .available,
         replies: [IOSServiceProbe.Reply] = []) {
        let probe = IOSServiceProbe(replies: replies)
        self.probe = probe
        service = IOSModelService(preference: preference, dependencies: IOSModelDependencies(
            availability: { availability },
            makeMLX: {
                probe.noteMLXLoad()
                return MLXModelService(sessionFactory: { progress in
                    progress(.downloading)
                    progress(.loading)
                    return IOSFixtureSession()
                })
            },
            makeFoundationModelsClient: { _, access, _ in IOSFixtureClient(access: access, probe: probe) }
        ))
    }

    func read(_ prompt: String) async throws -> String {
        let text = OSAllocatedUnfairLock(initialState: "")
        try await service.withResponse(prompt: prompt) { stream in
            for try await chunk in stream { text.withLock { $0 += chunk } }
        }
        return text.withLock { $0 }
    }
}

private final class IOSServiceProbe: Sendable {
    enum Reply: Sendable {
        case answer(String), pause(String), failure
        case reasonedAnswer(String, String), reasoningPause(String)
    }
    struct State: Sendable {
        var histories: [[ChatMessage]] = []
        var phases: [AIModelLoadPhase] = []
        var mlxLoads = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let replies: [Reply]
    var snapshot: State { state.withLock { $0 } }

    init(replies: [Reply]) { self.replies = replies }
    func record(_ phase: AIModelLoadPhase) { state.withLock { $0.phases.append(phase) } }
    func noteMLXLoad() { state.withLock { $0.mlxLoads += 1 } }
    func record(_ messages: [ChatMessage]) -> Reply {
        state.withLock {
            let index = $0.histories.count
            $0.histories.append(messages)
            return replies.indices.contains(index) ? replies[index] : .answer("Réponse")
        }
    }
}

private final class IOSFixtureSession: ModelSession {
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("Réponse MLX simulée"); $0.finish() }
    }
    func synchronize() async {}
    func reset(history: [AIChatMessage]) async throws {}
}

private final class IOSFixtureClient: NoctisAgentLLMClient {
    private let access: ModelGenerationAccess
    private let revision: Int
    private let probe: IOSServiceProbe
    var providerIdentifier: ProviderIdentifier { .mlx }

    init(access: ModelGenerationAccess, probe: IOSServiceProbe) {
        self.access = access
        self.probe = probe
        revision = access.revision
    }
    func beginRun() throws -> UUID { try access.acquire(revision: revision) }
    func endRun(_ lease: UUID) { access.release(lease) }

    func generate(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
                  requestContext: RequestContext?) async throws -> AssistantMessage {
        throw MLXModelServiceError.modelNotLoaded
    }

    func stream(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?)
        -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                var lease: UUID?
                defer { if let lease { access.release(lease) } }
                do {
                    if let shared = requestContext?.modelLease {
                        try access.validate(shared, revision: revision)
                    } else { lease = try beginRun() }
                    try Task.checkCancellation()
                    switch probe.record(messages) {
                    case .answer(let text): output.yield(.content(text))
                    case let .reasonedAnswer(reasoning, text):
                        output.yield(.reasoning(reasoning))
                        output.yield(.content(text))
                    case .reasoningPause(let text):
                        output.yield(.reasoning(text))
                        try await Task.sleep(for: .seconds(30))
                    case .pause(let text):
                        output.yield(.content(text))
                        try await Task.sleep(for: .seconds(30))
                    case .failure:
                        throw IOSModelServiceError.foundationModelsUnavailable(.modelNotReady)
                    }
                    output.yield(.finished(usage: nil))
                    output.yield(.streamClosed(terminalMarkerSeen: true))
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
