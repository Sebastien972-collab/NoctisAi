import Foundation
import Testing
import MLXLMCommon
@testable import Noctis

@Suite("Noctis LLM history serialization")
struct NoctisLLMClientHistoryTests {
    @Test func ordinaryTurnsKeepOrderAndDropTheTransportSystemMessage() {
        let messages: [ChatMessage] = [
            .system("Noctis identity"),
            .user("Bonjour"),
            .assistant(AssistantMessage(content: "Bonsoir")),
            .user("Comment vas-tu ?")
        ]

        let converted = NoctisLLMClient.messages(messages)

        #expect(converted.map(\.role) == [.user, .assistant, .user])
        #expect(converted.map(\.content) == ["Bonjour", "Bonsoir", "Comment vas-tu ?"])
    }

    @Test func toolTurnsPreserveTheToolMessageBoundaryAndStructuredArguments() {
        let arguments = NoctisLLMClient.decodedArguments(
            "{\"path\":\"Sources\",\"limit\":3,\"recursive\":true,\"filters\":[\"swift\"]}"
        )

        #expect(arguments["path"] == .string("Sources"))
        #expect(arguments["limit"] == .int(3))
        #expect(arguments["recursive"] == .bool(true))
        #expect(arguments["filters"] == .array([.string("swift")]))

        let messages: [ChatMessage] = [
            .user("Liste les fichiers"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call-1", name: "listFiles", arguments: "{\"path\":\"Sources\"}")
            ])),
            .tool(id: "call-1", name: "listFiles", content: "[\"Sources/Noctis\"]"),
            .assistant(AssistantMessage(content: "Voici le résultat."))
        ]

        let converted = NoctisLLMClient.messages(messages)
        #expect(converted.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(converted[2].content == "[\"Sources/Noctis\"]")
    }

    @Test func consecutiveProviderRequestsCanBeRehydratedFromCompleteHistory() {
        let first: [ChatMessage] = [.user("Un"), .assistant(AssistantMessage(content: "Deux"))]
        let second = first + [.user("Trois")]

        let firstMLX = NoctisLLMClient.messages(first)
        let secondMLX = NoctisLLMClient.messages(second)

        #expect(firstMLX.map(\.role) == [.user, .assistant])
        #expect(secondMLX.map(\.role) == [.user, .assistant, .user])
        #expect(Array(secondMLX.dropLast()).map(\.content) == firstMLX.map(\.content))
    }
}
