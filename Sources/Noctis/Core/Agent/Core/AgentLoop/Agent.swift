// Created by Sébastien DAGUIN
import Foundation

/// The core agent runtime that executes the generate, tool-call, repeat loop.
///
/// For a guide, see <doc:AgentAndChat>.
public final class Agent<C: ToolContext>: Sendable {
    let client: any LLMClient
    let tools: [any AnyTool<C>]
    let toolDefinitions: [ToolDefinition]
    let configuration: AgentConfiguration
    let completionPolicy: AgentCompletionPolicy
    let completionTool: (any AnyTool<C>)?

    /// Creates an agent that finishes through the built-in finish tool.
    public convenience init(
        client: any LLMClient,
        tools: [any AnyTool<C>],
        configuration: AgentConfiguration = AgentConfiguration()
    ) {
        self.init(client: client, tools: tools, completing: nil, configuration: configuration)
    }

    /// Creates an agent that finishes by executing `completionTool` instead of the built-in finish tool.
    ///
    /// The completion tool must be the only call in its assistant message; state that requirement in its description.
    public convenience init(
        client: any ToolCallSurfacingClient,
        tools: [any AnyTool<C>],
        completionTool: any AnyTool<C>,
        configuration: AgentConfiguration = AgentConfiguration()
    ) {
        self.init(client: client, tools: tools, completing: completionTool, configuration: configuration)
    }

    private init(
        client: any LLMClient,
        tools: [any AnyTool<C>],
        completing completionTool: (any AnyTool<C>)?,
        configuration: AgentConfiguration
    ) {
        var executableTools = tools
        if let completionTool {
            executableTools.append(completionTool)
        }
        let reservedNames: Set = ["finish", "prune_context"]
        let names = executableTools.map(\.name)
        precondition(!names.contains(where: \.isEmpty), "Tool names must be non-empty")
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys
        precondition(duplicates.isEmpty, "Duplicate tool names: \(duplicates.sorted().joined(separator: ", "))")
        let conflicts = names.filter { reservedNames.contains($0) }
        precondition(conflicts.isEmpty, "Reserved tool names: \(conflicts.sorted().joined(separator: ", "))")

        self.client = client
        self.tools = executableTools
        var defs = executableTools.map { ToolDefinition($0) }
        if completionTool == nil {
            defs.append(reservedFinishToolDefinition)
        }
        if configuration.contextBudget?.enablePruneTool == true {
            defs.append(reservedPruneContextToolDefinition)
        }
        toolDefinitions = defs
        self.configuration = configuration
        self.completionTool = completionTool
        completionPolicy = completionTool.map { .executableTool(name: $0.name) } ?? .builtInFinish
    }

    public func run(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AgentResult {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler
        )
        return try await run(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }

    public func run(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AgentResult {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler
        )
        return try await run(
            userMessage: userMessage, history: history,
            context: context, options: options
        )
    }

    public func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler,
            sessionID: sessionID ?? SessionID(), runID: RunID(),
            checkpointer: checkpointer
        )
        return stream(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }

    public func stream(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler,
            sessionID: sessionID ?? SessionID(), runID: RunID(),
            checkpointer: checkpointer
        )
        return stream(
            userMessage: userMessage, history: history,
            context: context, options: options
        )
    }

    func validateInvocation(_ options: InvocationOptions) {
        if let tokenBudget = options.tokenBudget {
            precondition(tokenBudget >= 1, "tokenBudget must be at least 1")
        }
        precondition(
            configuration.approvalPolicy == .none || options.approvalHandler != nil,
            "approvalHandler is required when approvalPolicy is not .none"
        )
    }
}

struct AgentLoopState {
    var messages: [ChatMessage]
    var historyWasRewrittenLocally: Bool = false
    var budgetPhase: ContextBudgetPhase?
    var sessionAllowlist: Set<String> = []
}

func shouldTerminateOnContent(
    client: any LLMClient,
    toolCalls: [ToolCall],
    content: String
) -> Bool {
    client is any ContentOnlyTerminatingClient && toolCalls.isEmpty && !content.isEmpty
}
