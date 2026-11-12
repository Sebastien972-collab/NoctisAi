// Created by Sébastien DAGUIN

import Foundation
import os
import MLXLMCommon
import NoctisAgent

/// Authorization is granted by the host, never by a model-generated tool call.
public protocol WorkspaceAuthorizing: Sendable {
    func authorizeWorkspace(_ workspace: AuthorizedWorkspace?) async throws
}

final class WorkspaceToolAccess: Sendable {
    private let state = OSAllocatedUnfairLock<ToolRegistry?>(initialState: nil)

    var registry: ToolRegistry? { state.withLock { $0 } }

    func authorize(_ workspace: AuthorizedWorkspace?) {
        state.withLock { $0 = workspace.map { ToolRegistry(workspace: $0) } }
    }
}

actor ConversationToolDispatcher {
    private let registry: ToolRegistry
    private var remainingCalls = 8
    private var remainingBytes = 262_144
    private var identifiers = Set<String>()

    init(registry: ToolRegistry) { self.registry = registry }

    func execute(_ call: MLXLMCommon.ToolCall) throws -> String {
        try Task.checkCancellation()
        guard remainingCalls > 0 else { throw AgentError.iterationLimit }
        remainingCalls -= 1
        let validated = try MLXModelService.agentCall(call)
        guard identifiers.insert(validated.id).inserted else { throw AgentError.invalidToolCall }
        let output = try registry.execute(validated)
        guard output.utf8.count <= remainingBytes else { throw AgentError.contextLimit }
        remainingBytes -= output.utf8.count
        return output
    }
}

actor LoadedAgentModel {
    private var model: ModelContainer?

    func set(_ model: ModelContainer) { self.model = model }
    func get() -> ModelContainer? { model }
}

extension MLXModelService: AgentModel {
    static func conversationToolSchemas(registry: ToolRegistry?) -> [ToolSpec] {
        NoctisToolRegistry(workspace: registry).schemas
    }

    /// Reuses the loaded MLX weights; the runtime owns dispatch, history and iteration limits.
    public func makeAgentRuntime(
        workspace: AuthorizedWorkspace, limits: AgentLimits
    ) -> AgentRuntime {
        AgentRuntime(model: self, registry: ToolRegistry(workspace: workspace), limits: limits)
    }

    static func agentSchemas(_ tools: [AgentToolSchema]) -> [ToolSpec] {
        tools.map { tool in
            let properties: [String: any Sendable] = tool.properties.mapValues {
                ["type": "string", "description": $0] as [String: any Sendable]
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name, "description": tool.description,
                    "parameters": [
                        "type": "object", "properties": properties,
                        "required": tool.required, "additionalProperties": false
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ]
        }
    }

    static func agentMessages(_ messages: [AgentMessage]) -> [MLXLMCommon.Chat.Message] {
        messages.map { message in
            switch message.role {
            case .user: return .user(message.content)
            case .assistant:
                let calls = message.calls.map { call in
                    MLXLMCommon.ToolCall(function: .init(name: call.name, arguments: call.arguments.mapValues {
                        JSONValue.string($0)
                    }), id: call.id)
                }
                return .assistant(message.content, toolCalls: calls.isEmpty ? nil : calls)
            case .tool: return .tool(message.content, id: message.callID, name: message.toolName)
            }
        }
    }

    static func agentCall(_ call: MLXLMCommon.ToolCall) throws -> AgentToolCall {
        var arguments: [String: String] = [:]
        for (key, value) in call.function.arguments {
            guard case .string(let text) = value else { throw AgentError.invalidArguments }
            arguments[key] = text
        }
        // Mistral templates require generated correlation IDs to contain nine alphanumeric characters.
        let fallbackID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9))
        return AgentToolCall(id: call.id ?? fallbackID, name: call.function.name, arguments: arguments)
    }

    static func generateAgentResponse(
        model: ModelContainer, messages: [AgentMessage], tools: [AgentToolSchema], limits: AgentLimits,
        presentation: NoctisPresentationInstructions = .markdown
    ) async throws -> AgentResponse {
        let registry = NoctisToolRegistry(agentTools: tools)
        let session = ChatSession(
            model,
            instructions: NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation),
            generateParameters: .init(maxTokens: 2_048),
            tools: registry.schemas
        )
        let cancellation = GenerationCancellation()
        let upstream = session.streamDetails(to: agentMessages(messages))
        let reader = Task {
            try await collectAgentResponse(upstream, cancellation: cancellation, limits: limits)
        }
        // The same cancellation handshake as chat prevents synchronize() from overtaking prefill.
        // GenerationCancellation accepts a Void reader, so join the typed reader through a bridge.
        let bridge = Task<Void, Error> {
            try await withTaskCancellationHandler {
                _ = try await reader.value
            } onCancel: { reader.cancel() }
        }
        cancellation.install(bridge)
        let result = await withTaskCancellationHandler {
            await reader.result
        } onCancel: { cancellation.cancel() }
        await session.synchronize()
        cancellation.clear()
        _ = await bridge.result
        if cancellation.isCancelled { throw CancellationError() }
        return try result.get()
    }
    private static func collectAgentResponse(
        _ upstream: AsyncThrowingStream<Generation, Error>,
        cancellation: GenerationCancellation, limits: AgentLimits
    ) async throws -> AgentResponse {
        var text = ""
        var calls: [AgentToolCall] = []
        var failure: (any Error)?
        for try await event in upstream {
            cancellation.arm()
            if cancellation.isCancelled || failure != nil { continue }
            do {
                try consumeAgentEvent(event, text: &text, calls: &calls, limits: limits)
            } catch { failure = error }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return AgentResponse(text: text, calls: calls)
    }

    private static func consumeAgentEvent(
        _ event: Generation, text: inout String, calls: inout [AgentToolCall], limits: AgentLimits
    ) throws {
        switch event {
        case .chunk(let chunk):
            guard text.utf8.count + chunk.utf8.count <= limits.responseBytes else {
                throw AgentError.responseLimit
            }
            text += chunk
        case .toolCall(let call):
            guard calls.count < limits.callsPerTurn else { throw AgentError.invalidToolCall }
            calls.append(try agentCall(call))
        case .rejectedToolCall: throw AgentError.invalidToolCall
        case .info(let info):
            if info.stopReason == .length { throw AgentError.responseLimit }
            if info.stopReason == .cancelled { throw CancellationError() }
        }
    }

}
