// Created by Sébastien DAGUIN
#if os(iOS)
import Foundation
import NoctisAgent

/// iOS entry point for local inference. Provider selection is fixed after a successful load.
public actor IOSModelService: AIModelService, WorkspaceAuthorizing {
    public let preference: IOSModelPreference
    public private(set) var selection: IOSModelSelection?
    public var foundationModelsAvailability: IOSFoundationModelsAvailability { dependencies.availability() }
    public private(set) var loadState = MLXModelService.LoadState.notLoaded
    public private(set) var conversationHistory: [ChatMessage] = []

    private let dependencies: IOSModelDependencies
    private let presentation: NoctisPresentationInstructions
    private let web: WebToolDispatcher
    private let generationAccess = ModelGenerationAccess()
    private let workspaceAccess = WorkspaceToolAccess()
    private var authorizedWorkspace: AuthorizedWorkspace?
    private var mlx: MLXModelService?
    private var isChangingSession = false
    private var isStartingGeneration = false
    private var cancellationRevision = 0
    private var generation: ActiveGeneration?
    private var issuedAgents: [AgentReference] = []

    private final class AgentReference {
        weak var agent: NoctisCLIAgent?
        init(_ agent: NoctisCLIAgent) { self.agent = agent }
    }

    private struct ActiveGeneration {
        let id: UUID
        let agent: NoctisCLIAgent
        let task: Task<Void, Never>
    }

    public init(
        preference: IOSModelPreference = .automatic,
        presentation: NoctisPresentationInstructions = .markdown
    ) {
        self.init(preference: preference, webSearchService: SearXNGService(), presentation: presentation)
    }

    public init(
        preference: IOSModelPreference = .automatic,
        webSearchService: any WebSearchService,
        presentation: NoctisPresentationInstructions = .markdown
    ) {
        self.preference = preference
        self.presentation = presentation
        dependencies = .live(webSearchService: webSearchService, presentation: presentation)
        web = WebToolDispatcher(searchService: webSearchService, pasgeService: HTTPWebPageService())
    }

    init(preference: IOSModelPreference, dependencies: IOSModelDependencies,
         webSearchService: any WebSearchService = SearXNGService(),
         presentation: NoctisPresentationInstructions = .markdown) {
        self.preference = preference
        self.dependencies = dependencies
        self.presentation = presentation
        web = WebToolDispatcher(searchService: webSearchService, pasgeService: HTTPWebPageService())
    }

    public func load() async throws { try await load(progress: { _ in }) }

    public func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws {
        try Task.checkCancellation()
        guard !isChangingSession else { throw MLXModelServiceError.generationInProgress }
        switch loadState {
        case .loaded: progress(.ready); return
        case .loading: throw MLXModelServiceError.modelLoading
        case .notLoaded, .failed: break
        }
        loadState = .loading
        let relay = IOSLoadProgressRelay(progress)
        relay.emit(.loading)
        do {
            let availability = dependencies.availability()
            let selected = try IOSModelConfiguration.select(
                preference: preference, availability: availability
            )
            if selected.provider == .mlx {
                let model = mlx ?? dependencies.makeMLX()
                mlx = model
                try await model.authorizeWorkspace(authorizedWorkspace)
                try await model.load { phase in
                    if phase != .ready { relay.emit(phase) }
                }
            }
            selection = selected
            loadState = .loaded
            relay.emit(.ready)
        } catch {
            loadState = .failed
            throw error
        }
    }

    public func makeNoctisCLIAgent() async throws -> NoctisCLIAgent {
        try ensureReady()
        return try await makeAgent()
    }

    /// Exposes the provider abstraction; supplied tool calls are still executed by the host.
    public func makeLLMClient() async throws -> any LLMClient {
        try ensureReady()
        if selection?.provider == .mlx, let mlx { return try await mlx.makeNoctisLLMClient() }
        return try makeFoundationClient()
    }

    public func authorizeWorkspace(_ workspace: AuthorizedWorkspace?) async throws {
        try Task.checkCancellation()
        guard loadState != .loading, !isChangingSession, !isStartingGeneration else {
            throw MLXModelServiceError.generationInProgress
        }
        isChangingSession = true
        defer { isChangingSession = false }
        await settleAgents()
        let lease = try generationAccess.acquire()
        defer { generationAccess.release(lease) }
        try Task.checkCancellation()
        try await mlx?.authorizeWorkspace(workspace)
        conversationHistory = []
        authorizedWorkspace = workspace
        workspaceAccess.authorize(workspace)
        generationAccess.invalidate()
        try Task.checkCancellation()
    }

    public func resetConversation(history: [AIChatMessage]) async throws {
        try ensureReady()
        isChangingSession = true
        defer { isChangingSession = false }
        await settleAgents()
        let lease = try generationAccess.acquire()
        defer { generationAccess.release(lease) }
        try Task.checkCancellation()
        try await mlx?.resetConversation(history: history)
        conversationHistory = history.map {
            switch $0.role {
            case .user: .user($0.content)
            case .assistant: .assistant(AssistantMessage(content: $0.content))
            case .system: .system($0.content)
            }
        }
        generationAccess.invalidate()
    }

    public func cancelGeneration() async {
        cancellationRevision &+= 1
        let current = generation
        current?.task.cancel()
        current?.agent.endSession()
        await current?.task.value
    }

    private func ensureReady() throws {
        try Task.checkCancellation()
        guard loadState == .loaded else { throw MLXModelServiceError.modelNotLoaded }
        guard !isChangingSession, !isStartingGeneration else { throw MLXModelServiceError.generationInProgress }
    }

    private func makeFoundationClient() throws -> any NoctisAgentLLMClient {
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        let presentation = presentation
        let instructions: @Sendable () -> String = {
            IOSSystemPromptBuilder.build(registry: registry, presentation: presentation)
        }
        return try dependencies.makeFoundationModelsClient(instructions(), generationAccess, instructions)
    }

    private func makeAgent() async throws -> NoctisCLIAgent {
        let agent: NoctisCLIAgent
        if selection?.provider == .mlx, let mlx {
            agent = try await mlx.makeNoctisCLIAgent()
        } else {
            agent = NoctisCLIAgent(
                client: try makeFoundationClient(), registry: NoctisToolRegistry(workspace: workspaceAccess.registry),
                web: web, configuration: AgentConfiguration(
                    maxIterations: 8, toolTimeout: .seconds(30), maxMessages: 12, maxToolResultCharacters: 4_096
                )
            )
        }
        issuedAgents.removeAll { $0.agent == nil }
        issuedAgents.append(AgentReference(agent))
        return agent
    }

    private func settleAgents() async {
        await cancelGeneration()
        let agents = issuedAgents.compactMap(\.agent)
        issuedAgents.removeAll()
        for agent in agents { agent.endSession() }
        for agent in agents { _ = await agent.settledHistory() }
    }
}

extension IOSModelService {
    public func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        try await startGeneration(prompt: prompt).stream
    }

    public func withResponse(
        prompt: String, consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void
    ) async throws {
        let response = try await startGeneration(prompt: prompt)
        do {
            try await consume(response.stream)
            try Task.checkCancellation()
        } catch {
            response.generation.task.cancel()
            response.generation.agent.endSession()
            await response.generation.task.value
            throw error
        }
        response.generation.task.cancel()
        response.generation.agent.endSession()
        await response.generation.task.value
    }

    private func startGeneration(prompt: String) async throws -> (
        stream: AsyncThrowingStream<String, Error>, generation: ActiveGeneration
    ) {
        try ensureReady()
        guard generation == nil else { throw MLXModelServiceError.generationInProgress }
        isStartingGeneration = true
        defer { isStartingGeneration = false }
        let revision = cancellationRevision
        let agent = try await makeAgent()
        try Task.checkCancellation()
        guard revision == cancellationRevision else {
            agent.endSession()
            throw CancellationError()
        }
        let id = UUID()
        let history = conversationHistory
        let (stream, output) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task {
            await produce(prompt: prompt, history: history, agent: agent, id: id, output: output)
        }
        let active = ActiveGeneration(id: id, agent: agent, task: task)
        generation = active
        output.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
                agent.endSession()
            }
        }
        return (stream, active)
    }

    private func produce(
        prompt: String, history: [ChatMessage], agent: NoctisCLIAgent, id: UUID,
        output: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        // The reader drains committed events after cancellation, preserving completed tool results.
        let reader = Task { await Self.readEvents(prompt: prompt, history: history, agent: agent, output: output) }
        let (transcript, failure) = await withTaskCancellationHandler {
            await reader.value
        } onCancel: { agent.endSession() }
        agent.endSession()
        _ = await agent.settledHistory()
        let error: (any Error)? = Task.isCancelled && !transcript.completed ? CancellationError() : failure
        if generation?.id == id {
            conversationHistory = Self.preservesPriorHistory(error) ? history : transcript.settled(error: error)
            generation = nil
        }
        output.finish(throwing: error)
    }

    private static func readEvents(
        prompt: String, history: [ChatMessage], agent: NoctisCLIAgent,
        output: AsyncThrowingStream<String, Error>.Continuation
    ) async -> (IOSConversationTranscript, (any Error)?) {
        var transcript = IOSConversationTranscript(history: history, prompt: prompt)
        var terminalError: (any Error)? = IOSModelServiceError.incompleteResponse
        do {
            for try await event in agent.stream(prompt: prompt, history: history) {
                transcript.observe(event)
                if case .delta(let text) = event.kind { output.yield(text) }
                if case .finished(_, _, let reason, _) = event.kind { terminalError = completionError(reason) }
            }
            return (transcript, terminalError)
        } catch { return (transcript, error) }
    }

    private static func preservesPriorHistory(_ error: (any Error)?) -> Bool {
        switch error as? MLXModelServiceError {
        case .contextLimit, .modelNotLoaded, .generationInProgress, .sessionInvalidated: true
        default: error as? AgentError == .contextLimit
        }
    }

    private static func completionError(_ reason: FinishReason?) -> (any Error)? {
        switch reason {
        case .completed: nil
        case .maxIterationsReached: MLXModelServiceError.toolLimit
        case .tokenBudgetExceeded: MLXModelServiceError.responseLimit
        default: IOSModelServiceError.incompleteResponse
        }
    }
}
#endif
