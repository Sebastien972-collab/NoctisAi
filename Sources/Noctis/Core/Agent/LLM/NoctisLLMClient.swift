// Created by Sébastien DAGUIN
import Foundation
import MLXLMCommon

/// Native AgentLoop client backed by the single MLX session owned by ModelSessionWorker.
///
/// MLX only surfaces tool calls here. AgentLoop remains the sole tool orchestrator.
public final class NoctisLLMClient: ToolCallSurfacingClient, ContentOnlyTerminatingClient, Sendable {
    private let worker: ModelSessionWorker
    private let systemPrompt: String
    private let access: ModelGenerationAccess
    private let revision: Int
    private let instructions: (@Sendable () -> String)?

    func beginRun() throws -> UUID { try access.acquire(revision: revision) }
    func endRun(_ lease: UUID) { access.release(lease) }

    init(worker: ModelSessionWorker, systemPrompt: String,
         access: ModelGenerationAccess = ModelGenerationAccess(), instructions: (@Sendable () -> String)? = nil) {
        self.worker = worker
        self.systemPrompt = systemPrompt
        self.access = access
        self.revision = access.revision
        self.instructions = instructions
    }

    public var contextWindowSize: Int? { nil }
    public var providerIdentifier: ProviderIdentifier { .mlx }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        var text = ""
        var calls: [ToolCall] = []
        for try await delta in stream(messages: messages, tools: tools, requestContext: requestContext) {
            switch delta {
            case .content(let value): text += value
            case .toolCallStart(let index, let id, let name, let kind):
                while calls.count <= index {
                    calls.append(ToolCall(id: id, name: name, arguments: "", kind: kind))
                }
            case .toolCallDelta(let index, let arguments):
                guard calls.indices.contains(index) else { continue }
                let call = calls[index]
                calls[index] = ToolCall(id: call.id, name: call.name, arguments: call.arguments + arguments,
                    kind: call.kind)
            case .reasoning, .reasoningDetails, .audioData, .audioTranscript, .audioStarted, .finished, .streamClosed:
                continue
            }
        }
        return AssistantMessage(content: text, toolCalls: calls)
    }

    public func stream(
        messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await produce(messages: messages, tools: tools, requestContext: requestContext, output: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct GenerationState {
        var identifiers: Set<String>
        var nextCallIndex = 0
        var hasContent = false
        var usage: TokenUsage?
    }

    private func produce(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?,
                         output: AsyncThrowingStream<StreamDelta, Error>.Continuation) async {
        let trace = requestContext?.agentTrace
        var lease: UUID?
        var acquired = false
        defer { if let lease { access.release(lease) } }
        do {
            if let shared = requestContext?.modelLease {
                try access.validate(shared, revision: revision)
            } else { lease = try beginRun() }
            acquired = true
            trace?.record(.generationStarted)
            try Task.checkCancellation()
            var state = GenerationState(identifiers: Set(messages.flatMap { message -> [String] in
                if case .assistant(let assistant) = message { return assistant.toolCalls.map(\.id) }
                return []
            }))
            let upstream = worker.streamDetails(messages: try Self.messages(messages), tools: tools.map(Self.tool),
                                                instructions: instructions?() ?? systemPrompt)
            for try await event in upstream {
                try Task.checkCancellation()
                try forward(event, tools: tools, state: &state, output: output, trace: trace)
            }
            guard state.hasContent || state.nextCallIndex > 0 else { throw AgentError.invalidToolCall }
            trace?.record(.generationCompleted)
            output.yield(.finished(usage: state.usage))
            output.yield(.streamClosed(terminalMarkerSeen: true))
            if let lease { access.release(lease) }
            output.finish()
        } catch {
            if acquired { await worker.synchronize() }
            trace?.record(error is CancellationError ? .generationCancelled : .generationFailed,
                          reason: AgentTraceEvent.Reason.classify(error))
            if let lease { access.release(lease) }
            output.finish(throwing: error)
        }
    }

    private func forward(_ event: Generation, tools: [ToolDefinition], state: inout GenerationState,
                         output: AsyncThrowingStream<StreamDelta, Error>.Continuation, trace: AgentTraceScope?) throws {
        switch event {
        case .chunk(let chunk):
            state.hasContent = state.hasContent || !chunk.isEmpty
            output.yield(.content(chunk))
        case .toolCall(let call):
            try forwardCall(call, tools: tools, state: &state, output: output, trace: trace)
        case .rejectedToolCall(let rejection):
            trace?.record(.toolRejected, reason: .rejected(rejection.reason))
            throw AgentError.invalidToolCall
        case .info(let info):
            state.usage = TokenUsage(input: info.promptTokenCount + info.cachedPromptTokenCount,
                                     output: info.generationTokenCount, cacheRead: info.cachedPromptTokenCount)
            if info.stopReason == .cancelled { throw CancellationError() }
            if info.stopReason == .length { throw MLXModelServiceError.responseLimit }
        }
    }

    private func forwardCall(_ call: MLXLMCommon.ToolCall, tools: [ToolDefinition], state: inout GenerationState,
                             output: AsyncThrowingStream<StreamDelta, Error>.Continuation,
                             trace: AgentTraceScope?) throws {
        let id = call.id ?? Self.makeCallID()
        guard Self.isValidCallID(id), state.identifiers.insert(id).inserted,
              tools.contains(where: { $0.name == call.function.name }) else {
            trace?.record(.toolRejected, reason: .invalidCall)
            throw AgentError.invalidToolCall
        }
        let index = state.nextCallIndex
        state.nextCallIndex += 1
        output.yield(.toolCallStart(index: index, id: id, name: call.function.name, kind: .function))
        let data = try JSONSerialization.data(withJSONObject: call.function.arguments.mapValues(\.anyValue),
                                              options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw AgentError.invalidArguments }
        output.yield(.toolCallDelta(index: index, arguments: json))
    }

    static func makeCallID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9))
    }

    static func isValidCallID(_ id: String) -> Bool {
        id.utf8.count == 9 &&
            id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    static func messages(_ messages: [ChatMessage]) throws -> [MLXLMCommon.Chat.Message] {
        try messages.validateForAgentHistory()
        var result: [MLXLMCommon.Chat.Message] = []
        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let text):
                result.append(.user(text))
            case .userMultimodal(let parts):
                let text = parts.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                result.append(.user(text))
            case .assistant(let assistant):
                let calls = try assistant.toolCalls.map { call in
                    guard isValidCallID(call.id) else { throw AgentError.invalidToolCall }
                    return MLXLMCommon.ToolCall(
                        function: .init(
                            name: call.name,
                            arguments: try decodedArguments(call.arguments)
                        ),
                        id: call.id
                    )
                }
                result.append(.assistant(assistant.content, toolCalls: calls.isEmpty ? nil : calls))
            case .tool(let id, let name, let content):
                result.append(.tool(content, id: id, name: name))
            }
        }
        return result
    }

    static func decodedArguments(_ json: String) throws -> [String: MLXLMCommon.JSONValue] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw AgentError.invalidArguments
        }
        return dictionary.mapValues(MLXLMCommon.JSONValue.from)
    }

    static func tool(_ definition: ToolDefinition) -> ToolSpec {
        [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": schema(definition.parametersSchema)
            ] as [String: any Sendable]
        ] as [String: any Sendable]
    }

    private static func schema(_ value: JSONSchema) -> [String: any Sendable] {
        switch value {
        case let .string(description, enumValues):
            var result: [String: any Sendable] = ["type": "string", "description": description ?? ""]
            if let enumValues { result["enum"] = enumValues }
            return result
        case let .integer(description):
            return ["type": "integer", "description": description ?? ""]
        case let .number(description):
            return ["type": "number", "description": description ?? ""]
        case let .boolean(description):
            return ["type": "boolean", "description": description ?? ""]
        case let .array(items, description):
            return ["type": "array", "items": schema(items), "description": description ?? ""]
        case let .object(properties, required, description):
            return [
                "type": "object", "properties": properties.mapValues(schema),
                "required": required, "additionalProperties": false, "description": description ?? ""
            ]
        case .null:
            return ["type": "null"]
        case let .anyOf(values):
            return ["anyOf": values.map(schema)]
        }
    }
}
