// Created by Sébastien DAGUIN

import Darwin
import Foundation
import Testing
import NoctisAgent
import MLXLMCommon
@testable import Noctis
@testable import NoctisCLI

@Suite("CLI agent en lecture seule", .timeLimit(.minutes(1)))
struct NoctisAgentCLITests {
    @Test("La conversation peut autoriser un dossier puis utiliser les outils sans changer de mode")
    func conversationUsesNativeTools() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("contenu du projet".utf8).write(to: directory.appendingPathComponent("example.swift"))
            let service = NativeCLIService()
            let initial = try AuthorizedWorkspace(authorizing: directory)
            try await service.authorizeWorkspace(initial)
            let input = "Bonjour\nAnalyse ce projet\n"
                + "Autre question\n/workspace off\nexit\n"
            try await runApplication(input: input, modelService: service)
            #expect(await service.prompts == ["Bonjour", "Analyse ce projet", "Autre question"])
            #expect(await service.authorizations == 2)
        }
        let output = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        #expect(output.contains("  ✦ Noctis\n\ncontenu du projet"))
        #expect(output.contains("  ✦ Noctis\n\nRéponse directe"))
    }

    @Test("Aucun workspace implicite ni argument invalide n’est accepté")
    func validatesWorkspaceArguments() throws {
        #expect(try NoctisCLI.authorizedWorkspace(arguments: []) == nil)
        #expect(try NoctisCLI.authorizedWorkspace(arguments: ["--workspace", "/private/tmp"]) != nil)
        for arguments in [["--workspace"], ["--workspace", "relative"], ["--unknown", "/private/tmp"],
                          ["--workspace", "/private/tmp", "extra"], ["--workspace", "/private/tmp/does-not-exist"]] {
            #expect(throws: NoctisAgent.AgentError.self) { try NoctisCLI.authorizedWorkspace(arguments: arguments) }
        }
    }

    @Test("Ministral est le modèle par défaut")
    func ministralIsDefaultModel() {
        #if os(macOS)
        #expect(NoctisConfiguration.modelID == "mlx-community/Ministral-3-14B-Instruct-2512-4bit")
        #else
        #expect(NoctisConfiguration.modelID == "mlx-community/Ministral-3-3B-Instruct-2512-4bit")
        #endif
    }

}

private actor NativeCLIService: AIModelService, WorkspaceAuthorizing {
    private var registry: ToolRegistry?
    private(set) var prompts: [String] = []
    private(set) var authorizations = 0

    func load() async throws {}
    func resetConversation(history: [AIChatMessage]) async throws {}
    func cancelGeneration() async {}

    func authorizeWorkspace(_ workspace: AuthorizedWorkspace?) async throws {
        registry = workspace.map { ToolRegistry(workspace: $0) }
        authorizations += 1
    }

    func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        var text = "Réponse directe"
        if prompt.hasPrefix("Analyse"), let registry {
            let dispatcher = ConversationToolDispatcher(registry: registry)
            let result = try await dispatcher.execute(ToolCall(
                function: .init(name: "readFile", arguments: ["path": JSONValue.string("example.swift")]), id: "read"
            ))
            #expect(result.contains("contenu du projet"))
            text = "contenu du projet"
        }
        let response = text
        return AsyncThrowingStream { output in
            output.yield(response)
            output.finish()
        }
    }

    func withResponse(prompt: String,
                      consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void) async throws {
        let stream = try await generate(prompt: prompt)
        try await consume(stream)
    }
}

private func runApplication(input: String, modelService: any AIModelService) async throws {
    let isExitTest = ExitTest.current != nil
    try #require(isExitTest)
    let pipe = Pipe()
    try #require(dup2(pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO) != -1)
    try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try pipe.fileHandleForWriting.close()
    await NoctisApplication(modelService: modelService).run()
}
