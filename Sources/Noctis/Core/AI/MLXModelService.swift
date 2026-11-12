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
import HuggingFace
import Tokenizers
import MLXHuggingFace

private final class MLXChatSession: StructuredModelSession {
    private let model: ModelContainer
    private var session: ChatSession
    private let workspaceAccess: WorkspaceToolAccess
    private let webDispatcher: WebToolDispatcher
    private let presentation: NoctisPresentationInstructions
    private var additionalInstructions: [String] = []

    init(
        model: ModelContainer, session: ChatSession,
        workspaceAccess: WorkspaceToolAccess, webDispatcher: WebToolDispatcher,
        presentation: NoctisPresentationInstructions
    ) {
        self.model = model
        self.session = session
        self.workspaceAccess = workspaceAccess
        self.webDispatcher = webDispatcher
        self.presentation = presentation
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        session.instructions = ([NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation)]
            + additionalInstructions).joined(separator: "\n\n")
        session.tools = registry.schemas
        let dispatcher = NoctisToolDispatcher(registry: registry, web: webDispatcher)
        session.toolDispatch = { call in try await dispatcher.execute(call) }
        session.generateParameters.maxTokens = registry.hasWorkspace ? 2_048 : nil
        return session.streamResponse(to: prompt)
    }

    func synchronize() async {
        await session.synchronize()
    }

    func streamDetails(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec],
        instructions: String
    ) -> AsyncThrowingStream<Generation, Error> {
        // AgentLoop sends its complete transcript on every provider turn.  A
        // persistent ChatSession would append that transcript to its own
        // conversation again, producing duplicate roles and an invalid Jinja
        // input on the second turn. Rehydrate one sequential cache from the
        // complete transcript, then append only the pending message.
        guard let pending = messages.last else {
            return session.streamDetails(to: [])
        }
        session = ChatSession(
            model,
            instructions: instructions,
            history: Array(messages.dropLast()),
            speculativeDecoding: session.speculativeDecoding,
            generateParameters: session.generateParameters,
            components: session.components,
            processing: session.processing,
            additionalContext: session.additionalContext,
            tools: tools,
            toolDispatch: nil
        )
        // AgentLoop owns every tool execution. MLX must only surface calls.
        session.generateParameters.maxTokens = 2_048
        return session.streamDetails(to: [pending])
    }

    func reset(history: [AIChatMessage]) async throws {
        additionalInstructions = []
        let messages: [MLXLMCommon.Chat.Message] = history.compactMap {
            switch $0.role {
            case .user: return .user($0.content)
            case .assistant: return .assistant($0.content)
            case .system:
                additionalInstructions.append($0.content)
                return nil
            }
        }
        // Reuse the weights with a fresh cache; the stable MLX release has no fork API.
        session = ChatSession(
            model,
            instructions: ([NoctisSystemPromptBuilder.build(
                registry: NoctisToolRegistry(workspace: workspaceAccess.registry), presentation: presentation
            )] + additionalInstructions).joined(separator: "\n\n"),
            history: messages,
            speculativeDecoding: session.speculativeDecoding,
            generateParameters: session.generateParameters,
            components: session.components,
            processing: session.processing,
            additionalContext: session.additionalContext,
            tools: session.tools,
            toolDispatch: session.toolDispatch
        )
    }
}

/// Resolve the installed snapshot before allowing any request to the Hub.
struct CachedModelDownloader: Downloader {
    let client: HubClient
    let phase: @Sendable (AIModelLoadPhase) -> Void

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw CocoaError(.fileReadInvalidFileName) }
        let cached: URL?
        do {
            cached = try await client.downloadSnapshot(
                of: repo, revision: revision ?? "main", matching: patterns, localFilesOnly: true
            )
        } catch HubCacheError.cachedPathResolutionFailed {
            cached = nil
        }
        if let cached, Self.isCompleteModel(at: cached) {
            phase(.loading)
            return cached
        }
        try Task.checkCancellation()
        phase(.downloading)
        let directory = try await client.downloadSnapshot(
            of: repo, revision: revision ?? "main", matching: patterns,
            progressHandler: { progressHandler($0) }
        )
        guard Self.isCompleteModel(at: directory) else { throw CocoaError(.fileReadCorruptFile) }
        phase(.loading)
        return directory
    }

    // A local-only Hub lookup can return a partially downloaded snapshot.
    static func isCompleteModel(at directory: URL) -> Bool {
        let files = FileManager.default
        func exists(_ name: String) -> Bool {
            let path = directory.appendingPathComponent(name).path
            return files.isReadableFile(atPath: path)
                && ((try? files.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0) > 0
        }
        guard ["config.json", "tokenizer_config.json", "tokenizer.json"].allSatisfy(exists) else {
            return false
        }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weights = json["weight_map"] as? [String: String], !weights.isEmpty,
           Set(weights.values).allSatisfy(exists) {
            return true
        }
        // Quantized repositories can retain an index from the unquantized model.
        // Accept their conventional shards only when the whole numbered set exists.
        let weights = (try? files.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("model") && $0.hasSuffix(".safetensors") } ?? []
        if weights == ["model.safetensors"] { return exists("model.safetensors") }
        guard let first = weights.first else { return false }
        let parts = first.replacingOccurrences(of: ".safetensors", with: "").split(separator: "-")
        guard parts.count == 4, parts[0] == "model", parts[2] == "of",
              let count = Int(parts[3]), count > 0, count == weights.count else { return false }
        return (1...count).allSatisfy {
            exists(String(format: "model-%05d-of-%05d.safetensors", $0, count))
        }
    }
}

public actor MLXModelService: AIModelService, WorkspaceAuthorizing {
    public enum LoadState: Equatable, Sendable {
        case notLoaded, loading, loaded, failed
    }

    public private(set) var loadState = LoadState.notLoaded
    private let workspaceAccess: WorkspaceToolAccess
    private let webDispatcher: WebToolDispatcher
    private let agentModelReference: LoadedAgentModel?
    private let presentation: NoctisPresentationInstructions
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
            let context = try await loadModel(
                from: CachedModelDownloader(client: HubClient(), phase: progress),
                using: #huggingFaceTokenizerLoader(),
                id: selectedModelID
            )
            let model = ModelContainer(context: context)
            await reference.set(model)
            let registry = NoctisToolRegistry(workspace: access.registry)
            let toolDispatcher = NoctisToolDispatcher(registry: registry, web: dispatcher)
            return MLXChatSession(model: model, session: ChatSession(
                model,
                instructions: NoctisSystemPromptBuilder.build(
                    registry: registry, presentation: presentation
                ),
                tools: registry.schemas,
                toolDispatch: { call in try await toolDispatcher.execute(call) }
            ), workspaceAccess: access, webDispatcher: dispatcher, presentation: presentation)
        }
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
        return NoctisCLIAgent(
            client: try makeNoctisLLMClient(), registry: registry, web: webDispatcher
        )
    }

    /// Returns an AgentLoop LLM client over the already loaded worker/session.
    /// No model or ChatSession is created here.
    public func makeNoctisLLMClient() throws -> NoctisLLMClient {
        guard loadState == .loaded, let worker else { throw MLXModelServiceError.modelNotLoaded }
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        return NoctisLLMClient(
            worker: worker,
            systemPrompt: NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation)
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
        // Reset before changing capability scopes: local file contents must never enter Web-only history.
        try await worker?.reset(history: [])
        try Task.checkCancellation()
        workspaceAccess.authorize(workspace)
    }

    public func resetConversation(history: [AIChatMessage]) async throws {
        guard let worker else { throw MLXModelServiceError.modelNotLoaded }
        guard !isResetting, !isAgentGenerating else { throw MLXModelServiceError.generationInProgress }
        isResetting = true
        defer { isResetting = false }
        await cancelGeneration()
        try Task.checkCancellation()
        try await worker.reset(history: history)
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
        try Task.checkCancellation()
        guard loadState == .loaded, let agentModelReference else {
            throw MLXModelServiceError.modelNotLoaded
        }
        guard generation == nil, !isResetting, !isAgentGenerating else {
            throw MLXModelServiceError.generationInProgress
        }
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
