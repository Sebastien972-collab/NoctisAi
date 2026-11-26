//
//  MLXModelService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//
import Foundation
import NoctisAgent
import MLXLMCommon
import MLXVLM
#if os(macOS)
import MLXLLM
#endif
import HuggingFace
import Tokenizers
import MLXHuggingFace

public actor MLXModelService: AIModelService, WorkspaceAuthorizing {
    public enum LoadState: Equatable, Sendable {
        case notLoaded, loading, loaded, failed
    }

    public private(set) var loadState = LoadState.notLoaded
    private let workspaceAccess: WorkspaceToolAccess
    private let webDispatcher: WebToolDispatcher
    private let agentModelReference: LoadedAgentModel?
    private let presentation: NoctisPresentationInstructions
    let generationAccess = ModelGenerationAccess()
    private final class AgentReference {
        weak var agent: NoctisCLIAgent?
        init(_ agent: NoctisCLIAgent) { self.agent = agent }
    }
    private var issuedAgents: [AgentReference] = []
    private var isAgentGenerating = false
    private let factory: ModelSessionWorker.Factory
    private var worker: ModelSessionWorker?
    private var generation: Task<Void, Never>?
    private var cancellation: GenerationCancellation?
    private var isResetting = false

    public init(presentation: NoctisPresentationInstructions = .markdown) {
        #if os(macOS)
        if let embedded = try? EmbeddedSearXNGService.bundled() {
            self.init(webSearchService: embedded, presentation: presentation)
            return
        }
        #endif
        self.init(webSearchService: SearXNGService(), presentation: presentation)
    }

    public init(modelID: String, presentation: NoctisPresentationInstructions = .markdown) {
        self.init(webSearchService: SearXNGService(), modelID: modelID, presentation: presentation)
    }

    public init(
        webSearchService: any WebSearchService, modelID: String? = nil,
        presentation: NoctisPresentationInstructions = .markdown
    ) {
        self.presentation = presentation
        let access = WorkspaceToolAccess()
        workspaceAccess = access
        let reference = LoadedAgentModel()
        agentModelReference = reference
        let selectedModelID = modelID ?? NoctisConfiguration.modelID
        let dispatcher = WebToolDispatcher(searchService: webSearchService, pasgeService: HTTPWebPageService())
        webDispatcher = dispatcher
        factory = { progress in
            let context = try await Self.loadContext(modelID: selectedModelID, progress: progress)
            let model = ModelContainer(context: context)
            let profile = await MLXModelProfile.resolve(model: model)
            let configurationURL = try await model.modelDirectory.appendingPathComponent("config.json")
            let data = try Data(contentsOf: configurationURL)
            let configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let text = configuration["text_config"] as? [String: Any] ?? configuration
            let window = text["max_position_embeddings"] as? Int ?? 8_192
            guard window > profile.maximumOutputTokens else { throw MLXModelServiceError.contextLimit }
            await model.update { context in
                context.processor = BoundedModelProcessor(
                    base: context.processor, maximumInputTokens: window - profile.maximumOutputTokens
                )
            }
            await reference.set(model)
            let registry = NoctisToolRegistry(workspace: access.registry)
            let toolDispatcher = NoctisToolDispatcher(registry: registry, web: dispatcher)
            return MLXChatSession(model: model, session: ChatSession(
                model,
                instructions: NoctisSystemPromptBuilder.build(
                    registry: registry, presentation: presentation
                ),
                generateParameters: profile.generationParameters,
                additionalContext: profile.additionalContext,
                tools: registry.schemas,
                toolDispatch: { call in try await toolDispatcher.execute(call) }
            ), workspaceAccess: access, webDispatcher: dispatcher, presentation: presentation, profile: profile)
        }
    }

    private static func loadContext(
        modelID: String, progress: @escaping @Sendable (AIModelLoadPhase) -> Void
    ) async throws -> sending ModelContext {
        let downloader = CachedModelDownloader(client: HubClient(), phase: progress)
        #if os(macOS)
        if modelID == MLXModelProfile.gptOSSModelID {
            return try await LLMModelFactory.shared.load(
                from: downloader, using: #huggingFaceTokenizerLoader(),
                configuration: .init(id: modelID, toolCallFormat: .gptOSS)
            )
        }
        #endif
        return try await loadModel(
            from: downloader, using: #huggingFaceTokenizerLoader(), id: modelID
        )
    }

    init(sessionFactory: @escaping ModelSessionWorker.Factory) {
        presentation = .markdown
        workspaceAccess = WorkspaceToolAccess()
        webDispatcher = WebToolDispatcher(searchService: SearXNGService(), pasgeService: HTTPWebPageService())
        agentModelReference = nil
        factory = sessionFactory
    }

    public func load() async throws {
        try await load(progress: { _ in })
    }

    /// Creates the CLI AgentLoop over the already loaded worker/session.
    /// No model or ChatSession is created here.
    public func makeNoctisCLIAgent() throws -> NoctisCLIAgent {
        guard loadState == .loaded, worker != nil else { throw MLXModelServiceError.modelNotLoaded }
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        guard !isResetting else { throw MLXModelServiceError.generationInProgress }
        let agent = NoctisCLIAgent(
            client: try makeNoctisLLMClient(), registry: registry, web: webDispatcher
        )
        issuedAgents.removeAll { $0.agent == nil }
        issuedAgents.append(AgentReference(agent))
        return agent
    }

    /// Returns an AgentLoop LLM client over the already loaded worker/session.
    /// No model or ChatSession is created here.
    public func makeNoctisLLMClient() throws -> NoctisLLMClient {
        guard loadState == .loaded, let worker else { throw MLXModelServiceError.modelNotLoaded }
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        let presentation = presentation
        return NoctisLLMClient(
            worker: worker,
            systemPrompt: NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation),
            access: generationAccess,
            instructions: { NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation) }
        )
    }

    public func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws {
        try Task.checkCancellation()
        switch loadState {
        case .loaded:
            progress(.ready)
            return
        case .loading:
            throw MLXModelServiceError.modelLoading
        case .notLoaded, .failed:
            break
        }
        loadState = .loading
        progress(.loading)
        do {
            worker = try await ModelSessionWorker.load(factory: factory, progress: progress)
            loadState = .loaded
            progress(.ready)
            // Loading is shared service state: once started, it completes even
            // if its caller cancels, avoiding an overlapping replacement load.
            try Task.checkCancellation()
        } catch {
            if worker == nil { loadState = .failed }
            throw error
        }
    }

    public func authorizeWorkspace(_ workspace: AuthorizedWorkspace?) async throws {
        try Task.checkCancellation()
        guard generation == nil, !isResetting, !isAgentGenerating, loadState != .loading else {
            throw MLXModelServiceError.generationInProgress
        }
        isResetting = true
        defer { isResetting = false }
        let agents = issuedAgents.compactMap(\.agent)
        issuedAgents.removeAll()
        for agent in agents { agent.endSession() }
        for agent in agents { _ = await agent.settledHistory() }
        let lease = try generationAccess.acquire()
        defer { generationAccess.release(lease) }
        // Reset before changing capability scopes: local file contents must never enter Web-only history.
        try await worker?.reset(history: [])
        try Task.checkCancellation()
        workspaceAccess.authorize(workspace)
        generationAccess.invalidate()
    }

    public func resetConversation(history: [AIChatMessage]) async throws {
        guard let worker else { throw MLXModelServiceError.modelNotLoaded }
        guard !isResetting, !isAgentGenerating else { throw MLXModelServiceError.generationInProgress }
        isResetting = true
        defer { isResetting = false }
        await cancelGeneration()
        try Task.checkCancellation()
        let lease = try generationAccess.acquire()
        defer { generationAccess.release(lease) }
        try await worker.reset(history: history)
        generationAccess.invalidate()
    }

    public func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        try startGeneration(prompt: prompt).stream
    }

    /// Scoped consumption guarantees cleanup on early return, thrown errors and
    /// cancellation, even if the caller retains a copy of the stream.
    public func withResponse(
        prompt: String,
        consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void
    ) async throws {
        let response = try startGeneration(prompt: prompt)
        do {
            try await consume(response.stream)
            try Task.checkCancellation()
        } catch {
            response.cancellation.cancel()
            await response.task.value
            throw error
        }
        response.cancellation.cancel()
        await response.task.value
    }

    private func startGeneration(prompt: String) throws -> (
        stream: AsyncThrowingStream<String, Error>,
        cancellation: GenerationCancellation,
        task: Task<Void, Never>
    ) {
        try Task.checkCancellation()
        guard let worker else { throw MLXModelServiceError.modelNotLoaded }
        guard generation == nil, !isResetting, !isAgentGenerating else {
            throw MLXModelServiceError.generationInProgress
        }

        let lease = try generationAccess.acquire()
        let (stream, output) = AsyncThrowingStream<String, Error>.makeStream()
        let cancellation = GenerationCancellation()
        self.cancellation = cancellation
        output.onTermination = { termination in
            if case .cancelled = termination { cancellation.cancel() }
        }
        let task = Task {
            var failure: (any Error)?
            do {
                try await worker.generate(
                    prompt: prompt, output: output, cancellation: cancellation
                )
            } catch {
                failure = error
            }
            self.generationAccess.release(lease)
            self.generation = nil
            self.cancellation = nil
            output.finish(throwing: failure)
        }
        generation = task
        return (stream, cancellation, task)
    }

    public func respond(
        messages: [AgentMessage], tools: [AgentToolSchema], limits: AgentLimits
    ) async throws -> AgentResponse {
        try await respond(messages: messages, tools: tools, limits: limits, revision: nil)
    }

    func respond(messages: [AgentMessage], tools: [AgentToolSchema], limits: AgentLimits,
                 revision: Int?) async throws -> AgentResponse {
        if let revision, revision != generationAccess.revision { throw MLXModelServiceError.sessionInvalidated }
        try Task.checkCancellation()
        guard loadState == .loaded, let agentModelReference else {
            throw MLXModelServiceError.modelNotLoaded
        }
        guard generation == nil, !isResetting, !isAgentGenerating else {
            throw MLXModelServiceError.generationInProgress
        }
        let lease = try generationAccess.acquire(revision: revision)
        defer { generationAccess.release(lease) }
        isAgentGenerating = true
        defer { isAgentGenerating = false }
        guard let model = await agentModelReference.get() else {
            throw MLXModelServiceError.modelNotLoaded
        }
        return try await Self.generateAgentResponse(
            model: model, messages: messages, tools: tools, limits: limits, presentation: presentation
        )
    }

    /// Waits for MLX's cache transaction to end before permitting another turn.
    public func cancelGeneration() async {
        let current = generation
        cancellation?.cancel()
        await current?.value
    }
}
