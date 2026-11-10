// Created by Sébastien DAGUIN

import Foundation

public enum AgentError: String, Error, Sendable {
    case invalidLimits, invalidArguments, invalidPath, accessDenied, ioFailure
    case notRegularFile, fileTooLarge, invalidUTF8, unsupportedTool
    case iterationLimit, busy, contextLimit, invalidToolCall, responseLimit, emptyResponse
}

public struct AgentLimits: Sendable {
    public let iterations: Int
    public let callsPerTurn: Int
    public let contextBytes: Int
    public let responseBytes: Int

    public init(iterations: Int = 8, callsPerTurn: Int = 4,
                contextBytes: Int = 262_144, responseBytes: Int = 32_768) throws {
        guard (1...32).contains(iterations), (1...8).contains(callsPerTurn),
              (1_024...1_048_576).contains(contextBytes),
              (256...65_536).contains(responseBytes) else { throw AgentError.invalidLimits }
        self.iterations = iterations
        self.callsPerTurn = callsPerTurn
        self.contextBytes = contextBytes
        self.responseBytes = responseBytes
    }
}

public struct AgentToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentResponse: Sendable, Equatable {
    public let text: String
    public let calls: [AgentToolCall]

    public init(text: String = "", calls: [AgentToolCall] = []) {
        self.text = text
        self.calls = calls
    }
}

public struct AgentMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant, tool }
    public let role: Role
    public let content: String
    public let calls: [AgentToolCall]
    public let callID: String?
    public let toolName: String?

    init(role: Role, content: String, calls: [AgentToolCall] = [],
         callID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.calls = calls
        self.callID = callID
        self.toolName = toolName
    }
}

public struct AgentSession: Sendable {
    public enum Status: Sendable { case ready, running, completed, iterationLimit, failed, cancelled }
    public let id = UUID()
    public internal(set) var messages: [AgentMessage] = []
    public internal(set) var status: Status = .ready
    public internal(set) var iterations = 0

    public init() {}
}

public protocol AgentModel: Sendable {
    func respond(messages: [AgentMessage], tools: [AgentToolSchema],
                 limits: AgentLimits) async throws -> AgentResponse
}

/// Extension points only. No implementation or dispatch route is enabled in this version.
public protocol AgentWorkspaceActions: Sendable {
    func applyPatch(_ patch: String) async throws -> String
    func runCommand(_ arguments: [String]) async throws -> String
    func gitDiff() async throws -> String
}
