// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
import NoctisAgent
@testable import Noctis

@Suite("MLX agent adapter without model loading")
struct MLXAgentModelTests {
    @Test func refusesUnloadedModel() async throws {
        let model = MLXModelService()
        await #expect(throws: MLXModelServiceError.modelNotLoaded) {
            try await model.respond(messages: [], tools: [], limits: AgentLimits())
        }
    }

    @Test func structuredCallsRequireStringArguments() throws {
        let call = MLXLMCommon.ToolCall(function: .init(name: "readFile", arguments: ["path": JSONValue.string("file.swift")]),
                            id: "call-1")
        let converted = try MLXModelService.agentCall(call)
        #expect(converted.id == "call-1")
        #expect(converted.arguments == ["path": "file.swift"])
        let unnamed = MLXLMCommon.ToolCall(function: call.function)
        let fallback = try MLXModelService.agentCall(unnamed)
        #expect(fallback.id.count == 9)
        #expect(fallback.id.allSatisfy { $0.isLetter || $0.isNumber })
        let invalid = MLXLMCommon.ToolCall(function: .init(name: "readFile", arguments: ["path": JSONValue.int(42)]))
        #expect(throws: Noctis.AgentError.invalidArguments) { try MLXModelService.agentCall(invalid) }
    }

    @Test func schemasDeclareOnlyReadOnlyTools() throws {
        let workspace = try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: "/private/tmp"))
        let schemas = MLXModelService.agentSchemas(ToolRegistry(workspace: workspace).schemas)
        #expect(schemas.count == 3)
        for schema in schemas {
            let function = try #require(schema["function"] as? [String: any Sendable])
            let parameters = try #require(function["parameters"] as? [String: any Sendable])
            #expect(parameters["additionalProperties"] as? Bool == false)
            #expect(["listFiles", "readFile", "searchCode"].contains(function["name"] as? String ?? ""))
        }
    }
    @Test func nativeSchemasFollowHostAuthorization() throws {
        let access = WorkspaceToolAccess()
        #expect(MLXModelService.conversationToolSchemas(registry: access.registry).count == 2)
        access.authorize(try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: "/private/tmp")))
        let names = MLXModelService.conversationToolSchemas(registry: access.registry).compactMap {
            ($0["function"] as? [String: any Sendable])?["name"] as? String
        }
        #expect(names == ["listFiles", "readFile", "searchCode"])
        access.authorize(nil)
        let revoked = MLXModelService.conversationToolSchemas(registry: access.registry)
        #expect((revoked[0]["function"] as? [String: any Sendable])?["name"] as? String == "web_search")
    }

    @Test func nativeDispatchIsReadOnlyAndBounded() async throws {
        let workspace = try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: "/private/tmp"))
        let dispatcher = ConversationToolDispatcher(registry: ToolRegistry(workspace: workspace))
        for index in 0..<8 {
            let result = try await dispatcher.execute(MLXLMCommon.ToolCall(
                function: .init(name: "runCommand", arguments: [:]), id: "call-\(index)"
            ))
            #expect(result.contains("unsupportedTool"))
        }
        await #expect(throws: Noctis.AgentError.iterationLimit) {
            try await dispatcher.execute(ToolCall(
                function: .init(name: "listFiles", arguments: ["path": JSONValue.string(".")]), id: "overflow"
            ))
        }
    }

    @Test func changingWorkspaceClearsConversationHistory() async throws {
        let audit = WorkspaceHistoryAudit()
        let service = MLXModelService(sessionFactory: { _ in WorkspaceHistorySession(audit: audit) })
        try await service.load()
        try await service.authorizeWorkspace(AuthorizedWorkspace(authorizing: URL(fileURLWithPath: "/private/tmp")))
        try await service.authorizeWorkspace(nil)
        let histories = await audit.histories
        #expect(histories.count == 2)
        #expect(histories.allSatisfy { $0.isEmpty })
    }

}

private actor WorkspaceHistoryAudit {
    var histories: [[AIChatMessage]] = []
    func record(_ history: [AIChatMessage]) { histories.append(history) }
}

private final class WorkspaceHistorySession: ModelSession {
    let audit: WorkspaceHistoryAudit
    init(audit: WorkspaceHistoryAudit) { self.audit = audit }
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func synchronize() async {}
    func reset(history: [AIChatMessage]) async throws { await audit.record(history) }
}
