import Foundation
import MLXLMCommon

private struct NoctisToolContext: ToolContext {
    let dispatcher: NoctisToolDispatcher
}

private struct NoctisDynamicTool: AnyTool {
    typealias Context = NoctisToolContext

    let entry: NoctisToolRegistry.Entry
    let parametersSchema: JSONSchema

    var name: String { entry.name }
    var description: String { entry.description }
    var isReadOnly: Bool { true }
    var isConcurrencySafe: Bool { false }

    func execute(arguments: Data, context: NoctisToolContext) async throws -> ToolResult {
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw AgentError.invalidArguments
        }
        var values: [String: MLXLMCommon.JSONValue] = [:]
        for (key, value) in object {
            guard let value = value as? String else { throw AgentError.invalidArguments }
            values[key] = .string(value)
        }
        let call = MLXLMCommon.ToolCall(
            function: .init(name: name, arguments: values),
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9))
        )
        return ToolResult(content: try await context.dispatcher.execute(call))
    }
}

/// CLI-facing AgentLoop wrapper. It owns no model and only references the loaded MLX worker.
public final class NoctisCLIAgent: Sendable {
    private let agent: Agent<NoctisToolContext>
    private let context: NoctisToolContext

    init(client: NoctisLLMClient, registry: NoctisToolRegistry, web: WebToolDispatcher) {
        let dispatcher = NoctisToolDispatcher(registry: registry, web: web)
        let tools = registry.entries.map { entry in
            NoctisDynamicTool(entry: entry, parametersSchema: Self.schemaFromToolSpec(entry.schema))
        }
        context = NoctisToolContext(dispatcher: dispatcher)
        agent = Agent(client: client, tools: tools, configuration: AgentConfiguration(
            maxIterations: 8,
            toolTimeout: .seconds(30),
            maxToolResultCharacters: 262_144
        ))
    }

    public func stream(
        prompt: String,
        history: [ChatMessage] = []
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        agent.stream(userMessage: prompt, history: history, context: context)
    }

    private static func schemaFromToolSpec(_ spec: ToolSpec) -> JSONSchema {
        let function = spec["function"] as? [String: any Sendable] ?? [:]
        let parameters = function["parameters"] as? [String: any Sendable] ?? [:]
        return schema(parameters)
    }

    private static func schema(_ value: [String: any Sendable]) -> JSONSchema {
        let type = value["type"] as? String
        let description = value["description"] as? String
        switch type {
        case "string":
            return .string(description: description)
        case "integer":
            return .integer(description: description)
        case "number":
            return .number(description: description)
        case "boolean":
            return .boolean(description: description)
        case "array":
            let items = value["items"] as? [String: any Sendable] ?? [:]
            return .array(items: schema(items), description: description)
        case "object":
            let rawProperties = value["properties"] as? [String: any Sendable] ?? [:]
            let properties = rawProperties.reduce(into: [String: JSONSchema]()) { result, item in
                if let property = item.value as? [String: any Sendable] {
                    result[item.key] = schema(property)
                }
            }
            let required = value["required"] as? [String] ?? []
            return .object(properties: properties, required: required, description: description)
        default:
            return .object(properties: [:], required: [], description: description)
        }
    }
}
