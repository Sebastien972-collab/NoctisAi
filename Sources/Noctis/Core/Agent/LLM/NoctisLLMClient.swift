import Foundation
import MLXLMCommon

/// Native AgentLoop client backed by the single MLX session owned by ModelSessionWorker.
///
/// MLX only surfaces tool calls here. AgentLoop remains the sole tool orchestrator.
public final class NoctisLLMClient: ToolCallSurfacingClient, Sendable {
    private let worker: ModelSessionWorker
    private let systemPrompt: String

    init(worker: ModelSessionWorker, systemPrompt: String) {
        self.worker = worker
        self.systemPrompt = systemPrompt
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
                calls[index] = ToolCall(id: call.id, name: call.name, arguments: call.arguments + arguments, kind: call.kind)
            case .reasoning, .reasoningDetails, .audioData, .audioTranscript, .audioStarted, .finished, .streamClosed:
                continue
            }
        }
        return AssistantMessage(content: text, toolCalls: calls)
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let mlxMessages = Self.messages(messages)
        let mlxTools = tools.map(Self.tool)
        let upstream = worker.streamDetails(
            messages: mlxMessages,
            tools: mlxTools,
            instructions: systemPrompt
        )
        return AsyncThrowingStream { continuation in
            Task {
                var nextCallIndex = 0
                do {
                    for try await event in upstream {
                        try Task.checkCancellation()
                        switch event {
                        case .chunk(let chunk):
                            continuation.yield(.content(chunk))
                        case .toolCall(let call):
                            let index = nextCallIndex
                            nextCallIndex += 1
                            continuation.yield(.toolCallStart(
                                index: index,
                                id: call.id ?? "mlx-\(index)",
                                name: call.function.name,
                                kind: .function
                            ))
                            let arguments = call.function.arguments.mapValues(\.anyValue)
                            if let data = try? JSONSerialization.data(withJSONObject: arguments),
                               let json = String(data: data, encoding: .utf8) {
                                continuation.yield(.toolCallDelta(index: index, arguments: json))
                            }
                        case .rejectedToolCall:
                            throw AgentError.invalidToolCall
                        case .info(let info):
                            if info.stopReason == .cancelled { throw CancellationError() }
                            if info.stopReason == .length { throw AgentError.responseLimit }
                        }
                    }
                    continuation.yield(.finished(usage: nil))
                    continuation.yield(.streamClosed(terminalMarkerSeen: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func messages(_ messages: [ChatMessage]) -> [MLXLMCommon.Chat.Message] {
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
                }.joined(separator: "\\n")
                result.append(.user(text))
            case .assistant(let assistant):
                let calls = assistant.toolCalls.map { call in
                    MLXLMCommon.ToolCall(
                        function: .init(
                            name: call.name,
                            arguments: decodedArguments(call.arguments)
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

    static func decodedArguments(_ json: String) -> [String: MLXLMCommon.JSONValue] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return [:]
        }
        return dictionary.mapValues(MLXLMCommon.JSONValue.from)
    }

    private static func tool(_ definition: ToolDefinition) -> ToolSpec {
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
            return ["type": "string", "description": description ?? "", "enum": enumValues ?? []]
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
