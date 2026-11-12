import Foundation

/// Per-request OpenAI Chat options that are not shared across all providers.
public struct OpenAIChatRequestOptions: Sendable, Equatable {
    public let toolChoice: OpenAIChatToolChoice?
    public let parallelToolCalls: Bool?
    public let customTools: [OpenAIChatCustomToolDefinition]

    public init(
        toolChoice: OpenAIChatToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        customTools: [OpenAIChatCustomToolDefinition] = []
    ) {
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.customTools = customTools
    }
}

/// Tool-selection controls for OpenAI Chat Completions.
public enum OpenAIChatToolChoice: Sendable, Equatable {
    case none
    case auto
    case required
    case function(name: String)
    case custom(name: String)
    case allowedTools(mode: OpenAIChatAllowedToolsMode = .auto, tools: [OpenAIChatAllowedTool])
}

/// How OpenAI Chat should treat an allowed-tools subset.
public enum OpenAIChatAllowedToolsMode: String, Sendable, Equatable, Codable {
    case auto
    case required
}

/// A tool reference used by OpenAI Chat `allowed_tools`.
public enum OpenAIChatAllowedTool: Sendable, Equatable {
    case function(name: String)
    case custom(name: String)
}

/// A custom tool definition for first-party OpenAI Chat Completions.
public struct OpenAIChatCustomToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let format: OpenAIChatCustomToolFormat?

    public init(
        name: String,
        description: String? = nil,
        format: OpenAIChatCustomToolFormat? = nil
    ) {
        self.name = name
        self.description = description
        self.format = format
    }
}

/// The input format accepted by a first-party OpenAI Chat custom tool.
public enum OpenAIChatCustomToolFormat: Sendable, Equatable {
    case text
    case grammar(definition: String, syntax: OpenAIChatCustomToolGrammarSyntax)
}

/// The grammar syntax for a first-party OpenAI Chat custom tool.
public enum OpenAIChatCustomToolGrammarSyntax: String, Sendable, Equatable, Codable {
    case lark
    case regex
}

/// Per-request metadata and provider-specific parameters.
public struct RequestContext: Sendable {
    var agentTrace: AgentTraceScope?
    public let extraFields: [String: JSONValue]
    public let onResponse: (@Sendable (HTTPURLResponse) -> Void)?
    /// Invoked synchronously for each live stream event; replayed events bypass it.
    public let onStreamEvent: (@Sendable (StreamEvent) -> Void)?
    /// Invoked at most once for each underlying LLM stream call.
    public let onStreamComplete: (@Sendable (StreamCompletion) -> Void)?
    public let openAIChat: OpenAIChatRequestOptions?
    public init(
        extraFields: [String: JSONValue] = [:],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil,
        onStreamEvent: (@Sendable (StreamEvent) -> Void)? = nil,
        onStreamComplete: (@Sendable (StreamCompletion) -> Void)? = nil,
        openAIChat: OpenAIChatRequestOptions? = nil,
    ) {
        self.extraFields = extraFields
        self.onResponse = onResponse
        self.onStreamEvent = onStreamEvent
        self.onStreamComplete = onStreamComplete
        self.openAIChat = openAIChat
    }
}
