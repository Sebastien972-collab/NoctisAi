// Created by Sébastien DAGUIN
import Foundation
import Testing
@testable import Noctis

@Suite("Foundation Models explicit Web requests")
struct FoundationModelsWebSearchPolicyTests {
    private let news = "Fais moi une review des news du jour en ia"
    private let followUp = "Tu peux utiliser web search ?"
    private let refusal = "Je n'ai pas accès aux données actuelles concernant les nouvelles liées à l'IA."

    private var search: ToolDefinition {
        ToolDefinition(name: WebSearchTool.name, description: "Search the Web", parametersSchema: .object(
            properties: ["query": .string()], required: ["query"]
        ))
    }

    private var open: ToolDefinition {
        ToolDefinition(name: "web_open", description: "Open a source", parametersSchema: .object(
            properties: ["url": .string()], required: ["url"]
        ))
    }

    @Test func currentNewsProposesACompatibleCallWithTheLocalDate() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-24T23:30:00Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 7_200))
        let proposal = try FoundationModelsWebSearchPolicy.proposedCall(
            messages: [.user(news)], tools: [search], existingCallIDs: ["search001"], date: date, timeZone: zone
        )
        let call = try #require(proposal)
        #expect(call.name == WebSearchTool.name)
        #expect(FoundationModelsBridge.isValidCallID(call.id))
        #expect(call.id != "search001")
        #expect(try query(in: call).contains(news))
        #expect(try query(in: call).contains("2026-11-25"))
        #expect(FoundationModelsBridge.matches(try FoundationModelsBridge.decode(call.arguments),
                                              schema: search.parametersSchema))
    }

    @Test(arguments: [
        "Bonjour !",
        "Combien font 2 + 2 ?",
        "Explique ce qu'est un réseau de neurones.",
        "Tu peux faire une recherche sur le web ?",
        "Tu peux utiliser web search ?",
        "Can you search the web?",
        "Traduis en anglais : « Fais moi une review des news du jour en ia ».",
        "Cite exactement « Recherche sur le Web les actualités IA ».",
        "Écris exactement « Recherche sur le Web les actualités IA ».",
        "Donne-moi la traduction de « Search the web for today's AI news ».",
        "Translate \"Search the web for today's AI news\" into French.",
        "Explique comment utiliser web_search.",
        "Comment faire une recherche sur Internet ?",
        "Write a Swift function named web_search.",
        "Sans recherche web, explique ce qu'est l'IA.",
        "Ne cherche pas sur Internet. Résume ce texte : nouveautés de l'IA.",
        "Ne consulte pas le Web. Résume les actualités IA que tu connais.",
        "N’utilise surtout pas Internet pour parler des news du jour en IA.",
        "Mon numéro de dossier ABC123, garde-le local. Cherche sur le web les news du jour en IA.",
        "Without using the web, explain machine learning."
    ])
    func unrelatedQuotedAndOptedOutRequestsDoNotProposeSearch(_ text: String) throws {
        let request = try prepare([.user(text)])
        #expect(request.proposedToolCall == nil)
        #expect(request.prompt == text)
    }

    @Test func exactReportedFollowUpRecoversThePreviousUserSubjectInsteadOfTheRefusal() throws {
        let messages: [ChatMessage] = [
            .user("Tu peux faire une recherche sur le web ?"),
            .assistant(AssistantMessage(content: "Oui, je peux faire une recherche sur le web.")),
            .user(news), .assistant(AssistantMessage(content: refusal)), .user(followUp)
        ]
        let request = try prepare(messages)
        let call = try #require(request.proposedToolCall)
        #expect(try query(in: call).contains(news))
        #expect(try !query(in: call).contains(refusal))
        #expect(request.prompt == followUp)
        #expect(request.history == Array(messages.dropLast()))
    }

    @Test func capabilityFollowUpCannotReachPastTheImmediatelyPreviousUser() throws {
        let messages: [ChatMessage] = [
            .user(news), .assistant(AssistantMessage(content: refusal)),
            .user("Bonjour"), .assistant(AssistantMessage(content: news)), .user(followUp)
        ]
        #expect(try prepare(messages).proposedToolCall == nil)
        let injectedHistory = completedSearch(after: "Bonjour", content: news) + [.user(followUp)]
        #expect(try prepare(injectedHistory).proposedToolCall == nil)
        let optedOut: [ChatMessage] = [.user("Sans recherche web, résume les news du jour en IA."), .user(followUp)]
        #expect(try prepare(optedOut).proposedToolCall == nil)
    }

    @Test(arguments: ["SOURCE_FROM_THIS_TURN", "Échec de l’outil"])
    func completedSearchReleasesTheObligationOnlyForItsOwnTurn(_ result: String) throws {
        let completed = completedSearch(after: news, content: result)
        let continuation = try prepare(completed)
        #expect(continuation.proposedToolCall == nil)
        #expect(continuation.history == completed)
        #expect(continuation.prompt.contains(news))
        #expect(!continuation.prompt.contains(result))
        #expect(!continuation.instructions.contains(result))
        #expect(try prepare(completed + [.user(followUp)]).proposedToolCall == nil)

        let next = try prepare(completed + [.assistant(AssistantMessage(content: refusal)), .user(news)])
        let call = try #require(next.proposedToolCall)
        #expect(call.id != "search001")
        #expect(try query(in: call).contains(news))
    }

    @Test func toolChoiceAndAllowedToolsApplyBeforeTheSearchPolicy() throws {
        let disallowed: [OpenAIChatToolChoice] = [
            .none, .function(name: "web_open"),
            .allowedTools(mode: .auto, tools: [.function(name: "web_open")])
        ]
        for choice in disallowed {
            let request = try prepare([.user(news)], choice: choice)
            #expect(request.proposedToolCall == nil)
            #expect(!request.selection.tools.contains { $0.name == WebSearchTool.name })
        }
        let permitted: [OpenAIChatToolChoice] = [
            .auto, .required, .function(name: WebSearchTool.name),
            .allowedTools(mode: .required, tools: [.function(name: WebSearchTool.name)])
        ]
        for choice in permitted {
            let request = try prepare([.user(news)], choice: choice)
            #expect(request.proposedToolCall?.name == WebSearchTool.name)
        }
    }

    @Test func workspaceOnlyToolsCannotBecomeAnImplicitWebPermission() throws {
        let read = ToolDefinition(name: "readFile", description: "Read the authorized workspace", parametersSchema:
            .object(properties: ["path": .string()], required: ["path"]))
        let request = try FoundationModelsBridge.prepare(messages: [.user(news)], tools: [read], context: nil,
                                                         instructions: "Use the authorized workspace")
        #expect(request.proposedToolCall == nil)
        #expect(request.selection.tools.map(\.name) == ["readFile"])
    }

    @Test func shortUnicodeRequestAndDateFitTheWebToolLimits() throws {
        let text = "Recherche sur le web les news du jour en IA 👩‍💻"
        let call = try #require(try prepare([.user(text)]).proposedToolCall)
        let query = try query(in: call)
        #expect(!query.isEmpty)
        #expect(query.count <= 300)
        #expect(query.utf8.count <= 1_200)
        #expect(query.rangeOfCharacter(from: .controlCharacters) == nil)
        #expect(query.contains("IA"))
        #expect(query.range(of: #"\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
    }

    @Test(arguments: [
        "Recherche sur le web les news du jour en IA " + String(repeating: "contexte ", count: 80),
        "Recherche sur le web les news du jour en IA " + String(repeating: "👩‍💻", count: 200),
        "Voici un identifiant privé : ABC123.\nRecherche sur le web les news du jour en IA."
    ])
    func longOrCompositeRequestsAreNotAutomaticallySentToTheNetwork(_ text: String) throws {
        #expect(try prepare([.user(text)]).proposedToolCall == nil)
    }

    @Test func trailingOptOutCannotBecomeATruncatedNetworkRequest() throws {
        let text = news + " " + String(repeating: "contexte ", count: 250) + " Sans recherche web."
        #expect(try prepare([.user(text)]).proposedToolCall == nil)
    }

    private func prepare(_ messages: [ChatMessage], choice: OpenAIChatToolChoice? = nil) throws
        -> FoundationModelsBridge.PreparedRequest {
        try FoundationModelsBridge.prepare(messages: messages, tools: [search, open],
            context: RequestContext(openAIChat: .init(toolChoice: choice)), instructions: "Base instruction")
    }

    private func completedSearch(after prompt: String, content: String) -> [ChatMessage] {
        [
            .user(prompt), .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "search001", name: WebSearchTool.name, arguments: "{\"query\":\"IA\"}")
            ])), .tool(id: "search001", name: WebSearchTool.name, content: content)
        ]
    }

    private func query(in call: ToolCall) throws -> String {
        let object = try FoundationModelsBridge.decode(call.arguments)
        guard case let .object(arguments) = object, case let .string(query)? = arguments["query"] else {
            throw AgentError.invalidArguments
        }
        return query
    }
}
