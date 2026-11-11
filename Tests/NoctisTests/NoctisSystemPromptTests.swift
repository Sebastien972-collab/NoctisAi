// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
import NoctisAgent
@testable import Noctis

@Suite("Session prompts and effective tool capabilities")
struct NoctisSystemPromptTests {
    @Test func identityIsIndependentOfCapabilities() {
        #expect(NoctisIdentity.text.contains("Tu es Noctis"))
        #expect(NoctisIdentity.text.contains("RELATION AVEC SÉBASTIEN"))
        #expect(NoctisIdentity.text.contains("Sois loyal sans servilité."))
        for value in ["web_search", "web_open", "listFiles", "CONTEXTE TEMPOREL", "FORMAT TERMINAL", "macOS"] {
            #expect(!NoctisIdentity.text.contains(value))
        }
    }

    @Test func dateAndPresentationAreExplicitAndDeterministic() throws {
        let date = Date(timeIntervalSince1970: 0)
        let zone = try #require(TimeZone(secondsFromGMT: -3_600))
        let context = NoctisRuntimeContext(date: date, timeZone: zone, platform: "iOS")
        let registry = NoctisToolRegistry()
        let plain = NoctisSystemPromptBuilder.build(registry: registry, context: context, presentation: .plainText)
        let rich = NoctisSystemPromptBuilder.build(registry: registry, context: context, presentation: .markdown)
        #expect(plain.contains("1969-12-31"))
        #expect(plain.contains("Plateforme : iOS"))
        #expect(plain.contains("sans syntaxe Markdown"))
        #expect(!rich.contains("sans syntaxe Markdown"))
        #expect(rich.contains("Le client accepte du Markdown simple"))
        let repeated = NoctisSystemPromptBuilder.build(
            registry: registry, context: context, presentation: .plainText
        )
        #expect(plain == repeated)
        let headings = ["IDENTITÉ", "FIABILITÉ", "SÉCURITÉ ET CONFIDENTIALITÉ", "OUTILS AUTORISÉS",
                        "CONTEXTE DE SESSION", "PRÉSENTATION"]
        let offsets = try headings.map { try #require(plain.range(of: $0)?.lowerBound) }
        #expect(offsets == offsets.sorted())
    }

    @Test func promptAndSchemasFollowPermissions() throws {
        let access = WorkspaceToolAccess()
        for authorized in [false, true, false] {
            let workspace = authorized ? try AuthorizedWorkspace(
                authorizing: URL(fileURLWithPath: "/private/tmp")
            ) : nil
            access.authorize(workspace)
            let registry = NoctisToolRegistry(workspace: access.registry)
            let names = try registry.schemas.map { schema in
                let function = try #require(schema["function"] as? [String: any Sendable])
                let parameters = try #require(function["parameters"] as? [String: any Sendable])
                #expect(parameters["additionalProperties"] as? Bool == false)
                return try #require(function["name"] as? String)
            }
            #expect(names == registry.entries.map(\.name))
            #expect(names == (authorized ? ["listFiles", "readFile", "searchCode"] : ["web_search"]))
            let prompt = NoctisSystemPromptBuilder.build(registry: registry)
            for name in names { #expect(prompt.contains("\(name) :")) }
            #expect(!prompt.contains("web_open"))
            #expect(!prompt.contains("/private/tmp"))
            #expect(!registry.permits(WebOpenTool.name))
            if authorized {
                #expect(!prompt.contains("web_search"))
                #expect(prompt.contains("Réseau désactivé"))
            } else {
                #expect(!prompt.contains("readFile"))
                #expect(prompt.contains("Aucun accès aux fichiers locaux"))
            }
        }
    }

    @Test func agentPromptUsesOnlySuppliedTools() throws {
        let local = ToolRegistry(workspace: try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: "/private/tmp")))
        let registry = NoctisToolRegistry(agentTools: Array(local.schemas.prefix(1)))
        let prompt = NoctisSystemPromptBuilder.build(registry: registry)
        #expect(registry.entries.map(\.name) == ["listFiles"])
        #expect(prompt.contains("listFiles :"))
        #expect(!prompt.contains("readFile"))
        #expect(!prompt.contains("web_search"))
    }

    @Test func everyAnnouncedToolHasWorkingDispatch() async throws {
        for authorized in [false, true] {
            let local = authorized ? ToolRegistry(workspace: try AuthorizedWorkspace(
                authorizing: URL(fileURLWithPath: "/private/tmp"))) : nil
            let registry = NoctisToolRegistry(workspace: local)
            let dispatcher = NoctisToolDispatcher(registry: registry, web: web)
            for entry in registry.entries {
                let arguments: [String: JSONValue]
                switch entry.name {
                case "web_search": arguments = ["query": .string("Swift")]
                case "searchCode": arguments = ["path": .string("missing-directory"), "query": .string("text")]
                default: arguments = ["path": .string("missing-file")]
                }
                // Missing files produce bounded domain errors, never undeclared_tool.
                let call = ToolCall(function: .init(name: entry.name, arguments: arguments))
                let output = try await dispatcher.execute(call)
                #expect(!output.contains("unsupportedTool"))
                #expect(!output.contains("undeclared_tool"))
            }
            for name in ["unknown", "web_open", authorized ? "web_search" : "readFile"] {
                await #expect(throws: WebToolError.self) {
                    try await dispatcher.execute(ToolCall(function: .init(name: name, arguments: [:])))
                }
            }
        }
    }

    @Test func ministralParserAcceptsExactlyTheDeclaredTools() throws {
        let workspace = ToolRegistry(workspace: try AuthorizedWorkspace(
            authorizing: URL(fileURLWithPath: "/private/tmp")))
        for registry in [NoctisToolRegistry(), NoctisToolRegistry(workspace: workspace)] {
            for entry in registry.entries {
                let arguments = entry.name == "web_search" ? ["query": "Swift"]
                    : entry.name == "searchCode" ? ["path": ".", "query": "Swift"] : ["path": "."]
                let json = try #require(String(data: JSONEncoder().encode(arguments), encoding: .utf8))
                let parser = ToolCallProcessor(format: .mistral, tools: registry.schemas,
                                               toolCallPolicy: .init(validation: .strict))
                _ = parser.processChunk("[TOOL_CALLS]\(entry.name)[ARGS]\(json)")
                parser.processEOS()
                #expect(parser.toolCalls.map { $0.function.name } == [entry.name])
                #expect(parser.rejectedToolCalls.isEmpty)
            }
            for name in ["unknown", "web_open"] {
                let parser = ToolCallProcessor(format: .mistral, tools: registry.schemas)
                _ = parser.processChunk("[TOOL_CALLS]\(name)[ARGS]{\"url\":\"https://www.swift.org\"}")
                parser.processEOS()
                #expect(parser.toolCalls.isEmpty)
                #expect(!parser.rejectedToolCalls.isEmpty)
            }
        }
    }

    @Test func concurrentDispatchHasOneSharedTurnBudget() async throws {
        let dispatcher = NoctisToolDispatcher(registry: NoctisToolRegistry(), web: web)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try await dispatcher.execute(ToolCall(function: .init(
                            name: "web_search", arguments: ["query": JSONValue.string("Swift")]
                        )))
                        return true
                    } catch { return false }
                }
            }
            var successes = 0
            for await value in group where value { successes += 1 }
            return successes
        }
        #expect(successes == 8)
    }

    @Test func reservedOpenContractIsStrictAndBlocked() async throws {
        let function = try #require(WebOpenTool.schema["function"] as? [String: any Sendable])
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        #expect(parameters["additionalProperties"] as? Bool == false)
        #expect(parameters["required"] as? [String] == ["url"])
        for arguments: [String: JSONValue] in [[:], ["url": .int(1)],
                                              ["url": .string("https://www.swift.org"), "extra": .string("x")]] {
            #expect(throws: WebToolError.self) {
                try WebOpenTool.validate(ToolCall(function: .init(name: WebOpenTool.name, arguments: arguments)))
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await #expect(throws: WebPageError.publicAccessDisabled) {
                        try await HTTPWebPageService().open(url: #require(URL(string: "https://www.swift.org")))
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private var web: WebToolDispatcher {
        WebToolDispatcher(searchService: PromptSearchStub(), pasgeService: HTTPWebPageService())
    }
}

private struct PromptSearchStub: WebSearchService {
    func search(query: String) async throws -> [SearchResult] { [] }
}
