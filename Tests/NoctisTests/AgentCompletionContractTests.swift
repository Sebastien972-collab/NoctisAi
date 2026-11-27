// Created by Sébastien DAGUIN

import Foundation
import Testing
import os
@testable import Noctis

@Suite("Agent final-answer contract", .timeLimit(.minutes(1)))
struct AgentCompletionContractTests {
    @Test func contentCapableClientsReceiveOnlyExecutableTools() async throws {
        let probe = CompletionContractProbe([.init(chunks: ["Bonjour"]), .init(chunks: ["Bonsoir"])])
        let agent = Agent(client: NaturalCompletionClient(probe: probe), tools: [CompletionContractTool("lookup")])
        let context = CompletionContractContext()

        let result = try await agent.run(userMessage: "Salut", context: context)
        #expect(result.content == "Bonjour")
        #expect(result.iterations == 1)
        let streamed = try await collect(agent, context: context)
        #expect(streamed.text == "Bonsoir")
        #expect(streamed.content == "Bonsoir")
        #expect(probe.requests.map(\.toolNames) == [["lookup"], ["lookup"]])
        #expect(context.executed.withLock { $0 }.isEmpty)
    }

    @Test(arguments: [
        #"{"content":"Bonjour"}"#,
        #"{"content":"Bonjour","reason":"completed"}"#,
        #"{"name":"lookup","arguments":{},"content":"Une donnée"}"#
    ])
    func requestedJSONIsPreservedAcrossEveryChunkBoundary(_ json: String) async throws {
        for offset in 0...json.count {
            let split = json.index(json.startIndex, offsetBy: offset)
            let chunks = [String(json[..<split]), String(json[split...])]
            let probe = CompletionContractProbe([.init(chunks: chunks)])
            let agent = Agent(client: NaturalCompletionClient(probe: probe),
                              tools: [CompletionContractTool("lookup")])
            let context = CompletionContractContext()
            let result = try await collect(agent, prompt: "Réponds avec ce JSON exact", context: context)

            #expect(result.text == json)
            #expect(result.content == json)
            #expect(result.history.last == .assistant(AssistantMessage(content: json)))
            #expect(context.executed.withLock { $0 }.isEmpty)
            #expect(probe.requests.count == 1)
        }
        let probe = CompletionContractProbe([.init(chunks: [json])])
        let agent = Agent<CompletionContractContext>(client: NaturalCompletionClient(probe: probe), tools: [])
        let result = try await agent.run(userMessage: "Réponds en JSON", context: CompletionContractContext())
        #expect(result.content == json)
    }

    @Test(arguments: ["", "Par", "Paris"])
    func alreadyReturnedNativeFinishStillDecodesWithoutPublishingArguments(_ prefix: String) async throws {
        let turn = CompletionContractTurn(chunks: [prefix], calls: [
            ToolCall(id: "finish001", name: "finish", arguments: #"{"content":"Paris"}"#)
        ])
        let probe = CompletionContractProbe([turn, turn, .init(chunks: ["Suite"])])
        let agent = Agent<CompletionContractContext>(client: NaturalCompletionClient(probe: probe), tools: [])
        let context = CompletionContractContext()
        let result = try await agent.run(userMessage: "Capitale ?", context: context)
        #expect(result.content == "Paris")
        let streamed = try await collect(agent, prompt: "Capitale ?", context: context)
        #expect(streamed.text == "Paris")
        #expect(streamed.content == "Paris")
        #expect(streamed.history == [.user("Capitale ?"), .assistant(AssistantMessage(content: "Paris"))])
        _ = try await agent.run(userMessage: "Encore", history: streamed.history, context: context)
        #expect(probe.requests.last?.messages == streamed.history + [.user("Encore")])
        #expect(probe.requests.allSatisfy { $0.toolNames.isEmpty })
    }

    @Test func clientsRequiringTerminalCallsKeepTheDeclaredFinishTool() async throws {
        let probe = CompletionContractProbe([.init(chunks: [], calls: [
            ToolCall(id: "finish001", name: "finish", arguments: #"{"content":"Terminé"}"#)
        ])])
        let agent = Agent(client: TerminalCompletionClient(probe: probe), tools: [CompletionContractTool("lookup")])
        let result = try await agent.run(userMessage: "Termine", context: CompletionContractContext())
        #expect(result.content == "Terminé")
        #expect(result.finishReason == .completed)
        #expect(probe.requests.map(\.toolNames) == [["lookup", "finish"]])
        #expect(result.history.last == .assistant(AssistantMessage(content: "Terminé")))
    }

    @Test func nativeToolsExecuteBeforeTheNaturalFinalAnswer() async throws {
        let probe = CompletionContractProbe([
            .init(chunks: [], calls: [ToolCall(id: "lookup001", name: "lookup", arguments: "{}")]),
            .init(chunks: ["Source trouvée"])
        ])
        let agent = Agent(client: NaturalCompletionClient(probe: probe), tools: [CompletionContractTool("lookup")])
        let context = CompletionContractContext()
        let result = try await collect(agent, context: context)
        #expect(result.text == "Source trouvée")
        #expect(context.executed.withLock { $0 } == ["lookup"])
        #expect(probe.requests.map(\.toolNames) == [["lookup"], ["lookup"]])
        #expect(probe.requests.last?.messages.last == .tool(
            id: "lookup001", name: "lookup", content: "Observed lookup"
        ))
    }

    @Test(arguments: [false, true])
    func explicitCompletionStillRequiresExecutingItsTool(streaming: Bool) async throws {
        let probe = CompletionContractProbe([
            .init(chunks: ["Préparation"]),
            .init(chunks: [], calls: [ToolCall(id: "done00001", name: "deliver", arguments: "{}")])
        ])
        let agent = Agent(client: NaturalCompletionClient(probe: probe),
                          tools: [CompletionContractTool("lookup")], completionTool: CompletionContractTool("deliver"))
        let context = CompletionContractContext()
        if streaming {
            let result = try await collect(agent, context: context)
            #expect(result.content == "Observed deliver")
        } else {
            let result = try await agent.run(userMessage: "Termine", context: context)
            #expect(result.content == "Observed deliver")
            #expect(result.iterations == 2)
        }
        #expect(context.executed.withLock { $0 } == ["deliver"])
        #expect(probe.requests.map(\.toolNames) == [["lookup", "deliver"], ["lookup", "deliver"]])
    }

    @Test func foundationModelsCanAnswerAndProposeToolsWithoutSyntheticFinish() throws {
        let agent = Agent(client: FoundationModelsWebFixtureClient(), tools: [CompletionContractTool("lookup")])
        let selection = try FoundationModelsBridge.selectTools(agent.toolDefinitions, context: nil)
        #expect(selection.tools.map(\.name) == ["lookup"])
        let answer = try FoundationModelsBridge.decodeStep(
            #"{"step":{"kind":"answer","content":"Bonjour"}}"#, selection: selection, existingCallIDs: []
        )
        #expect(answer.content == "Bonjour")
        #expect(answer.toolCalls.isEmpty)
        let call = try FoundationModelsBridge.decodeStep(
            #"{"step":{"kind":"tool","name":"lookup","arguments":{}}}"#,
            selection: selection, existingCallIDs: []
        )
        #expect(call.toolCalls.map(\.name) == ["lookup"])
    }

    private func collect(_ agent: Agent<CompletionContractContext>, prompt: String = "Bonjour",
                         context: CompletionContractContext)
    async throws -> CompletionContractResult {
        var text = ""
        var completions: [(String?, [ChatMessage])] = []
        for try await event in agent.stream(userMessage: prompt, context: context) {
            if case let .delta(chunk) = event.kind { text += chunk }
            if case let .finished(_, content, _, history) = event.kind { completions.append((content, history)) }
        }
        #expect(completions.count == 1)
        let final = try #require(completions.first)
        return CompletionContractResult(text: text, content: final.0, history: final.1)
    }
}

private struct CompletionContractResult: Sendable {
    let text: String
    let content: String?
    let history: [ChatMessage]
}

private struct CompletionContractTurn: Sendable {
    let chunks: [String]
    var calls: [ToolCall] = []
    var response: AssistantMessage { AssistantMessage(content: chunks.joined(), toolCalls: calls) }
}

private final class CompletionContractProbe: Sendable {
    struct Request: Sendable {
        let messages: [ChatMessage]
        let toolNames: [String]
    }
    private struct State {
        var turns: [CompletionContractTurn]
        var requests: [Request] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ turns: [CompletionContractTurn]) { state = OSAllocatedUnfairLock(initialState: State(turns: turns)) }
    var requests: [Request] { state.withLock { $0.requests } }

    func next(messages: [ChatMessage], tools: [ToolDefinition]) throws -> CompletionContractTurn {
        try state.withLock { state in
            state.requests.append(Request(messages: messages, toolNames: tools.map(\.name)))
            guard !state.turns.isEmpty else { throw TransportError.other("Unexpected extra generation") }
            return state.turns.removeFirst()
        }
    }
}

private protocol CompletionContractClient: ToolCallSurfacingClient {
    var probe: CompletionContractProbe { get }
}

private extension CompletionContractClient {
    var providerIdentifier: ProviderIdentifier { .mlx }

    func generate(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
                  requestContext: RequestContext?) async throws -> AssistantMessage {
        try probe.next(messages: messages, tools: tools).response
    }

    func stream(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?)
    -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { output in
            do {
                let turn = try probe.next(messages: messages, tools: tools)
                for chunk in turn.chunks { output.yield(.content(chunk)) }
                for (index, call) in turn.calls.enumerated() {
                    output.yield(.toolCallStart(index: index, id: call.id, name: call.name, kind: call.kind))
                    let split = call.arguments.index(call.arguments.startIndex, offsetBy: call.arguments.count / 2)
                    output.yield(.toolCallDelta(index: index, arguments: String(call.arguments[..<split])))
                    output.yield(.toolCallDelta(index: index, arguments: String(call.arguments[split...])))
                }
                output.yield(.finished(usage: nil))
                output.yield(.streamClosed(terminalMarkerSeen: true))
                output.finish()
            } catch { output.finish(throwing: error) }
        }
    }
}

private struct NaturalCompletionClient: CompletionContractClient, ContentOnlyTerminatingClient {
    let probe: CompletionContractProbe
}

private struct TerminalCompletionClient: CompletionContractClient {
    let probe: CompletionContractProbe
}

private final class CompletionContractContext: ToolContext {
    let executed = OSAllocatedUnfairLock(initialState: [String]())
}

private struct CompletionContractTool: AnyTool {
    let name: String
    init(_ name: String) { self.name = name }
    var description: String { "Record the observed tool execution" }
    var parametersSchema: JSONSchema { .object(properties: [:], required: []) }
    var isReadOnly: Bool { true }

    func execute(arguments: Data, context: CompletionContractContext) async throws -> ToolResult {
        context.executed.withLock { $0.append(name) }
        return ToolResult(content: "Observed \(name)")
    }
}
