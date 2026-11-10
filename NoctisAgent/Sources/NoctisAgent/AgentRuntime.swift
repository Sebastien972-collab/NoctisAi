// Created by Sébastien DAGUIN

import Foundation

public actor AgentRuntime {
    private let model: any AgentModel
    private let registry: ToolRegistry
    private let limits: AgentLimits
    private var active = false
    public private(set) var session = AgentSession()

    public init(model: any AgentModel, registry: ToolRegistry, limits: AgentLimits) {
        self.model = model
        self.registry = registry
        self.limits = limits
    }

    /// Each task starts a fresh transcript; the last complete or partial session remains inspectable.
    public func run(prompt: String) async throws -> AgentSession {
        guard !active else { throw AgentError.busy }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidArguments
        }
        active = true
        defer { active = false }
        session = AgentSession()
        session.status = .running
        do {
            try append(.init(role: .user, content: prompt))
            var callIDs = Set<String>()
            for iteration in 1...limits.iterations {
                try Task.checkCancellation()
                session.iterations = iteration
                let response = try await model.respond(
                    messages: session.messages, tools: registry.schemas, limits: limits
                )
                try Task.checkCancellation()
                guard response.text.utf8.count <= limits.responseBytes else { throw AgentError.responseLimit }
                guard response.calls.count <= limits.callsPerTurn else { throw AgentError.invalidToolCall }
                try validate(response.calls, callIDs: &callIDs)
                guard !response.text.isEmpty || !response.calls.isEmpty else { throw AgentError.emptyResponse }
                try append(.init(role: .assistant, content: response.text, calls: response.calls))
                if response.calls.isEmpty {
                    session.status = .completed
                    return session
                }
                for call in response.calls {
                    try Task.checkCancellation()
                    let result = try registry.execute(call)
                    try append(.init(role: .tool, content: result, callID: call.id, toolName: call.name))
                }
            }
            session.status = .iterationLimit
            return session
        } catch {
            session.status = error is CancellationError ? .cancelled : .failed
            throw error
        }
    }

    private func validate(_ calls: [AgentToolCall], callIDs: inout Set<String>) throws {
        // Validate the entire batch before executing any member of it.
        for call in calls {
            guard !call.id.isEmpty, call.id.utf8.count <= 128,
                  call.name.utf8.count <= 64, call.arguments.count <= 2,
                  call.arguments.allSatisfy({ $0.key.utf8.count <= 32 && $0.value.utf8.count <= 4_096 }),
                  callIDs.insert(call.id).inserted else { throw AgentError.invalidToolCall }
        }
    }

    private func append(_ message: AgentMessage) throws {
        // Include structured arguments and JSON escaping in the budget, not only visible text.
        let encoder = JSONEncoder()
        let size = try encoder.encode(session.messages).count + encoder.encode(message).count
        guard size <= limits.contextBytes else { throw AgentError.contextLimit }
        session.messages.append(message)
    }
}
