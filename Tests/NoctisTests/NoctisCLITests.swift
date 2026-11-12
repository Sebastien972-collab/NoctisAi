// Created by Sébastien DAGUIN

import Darwin
import Foundation
import Testing
import NoctisAgent
@testable import Noctis
@testable import NoctisCLI

@Suite("Global personal CLI", .timeLimit(.minutes(1)))
struct NoctisCLITests {
    @Test func parsesMaintenanceCommandsWithoutWorkspace() throws {
        #expect(try NoctisCLI.command(arguments: []) == .chat(nil))
        for (arguments, command) in [(["--help"], NoctisCLI.Command.help), (["-h"], .help),
                                     (["--version"], .version), (["doctor"], .doctor), (["update"], .update)] {
            #expect(try NoctisCLI.command(arguments: arguments) == command)
        }
        for arguments in [["unknown"], ["--workspace"], ["--workspace", "relative"], ["doctor", "extra"]] {
            #expect(throws: NoctisAgent.AgentError.invalidArguments) { try NoctisCLI.command(arguments: arguments) }
        }
    }

    @Test func maintenanceAndInteractiveCommandsDoNotLoadModel() async throws {
        try await #require(processExitsWith: .success) {
            let service = MockAIModelService()
            try await runGlobalCLI(input: "/help\n/model\n/permissions\n/workspace\n/clear\n/exit\n", service: service)
            #expect(service.calls.isEmpty)
        }
    }

    @Test func multilineInputReachesModelAsOnePrompt() async throws {
        try await #require(processExitsWith: .success) {
            let service = MockAIModelService(responses: [.chunks(["OK"])])
            try await runGlobalCLI(input: "Première ligne\\\ndeuxième ligne\n/exit\n", service: service)
            #expect(service.calls == [.load, .generate("Première ligne\ndeuxième ligne")])
        }
    }

    @Test func redirectedInputCannotGrantNewWorkspaceAccess() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let service = MLXModelService()
            try await runGlobalCLI(input: "/workspace /private/tmp\n/exit\n", service: service)
            #expect(await service.loadState == .notLoaded)
        }
        let output = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        #expect(output.contains(localizedCLI("console.workspace.explicit_flag")))
    }

    @Test func plainOutputPreservesMarkdownAndRemovesTerminalControls() {
        var renderer = TerminalMarkdown(styled: false)
        #expect(renderer.append("# Titre\n**gras**\n```swift\nlet x = 1\n```\n")
                == "# Titre\n**gras**\n```swift\nlet x = 1\n```\n")
        let output = renderer.append("A\u{1B}[31mB\u{07}\u{9B}C") + renderer.finish()
        #expect(!output.contains("\u{1B}"))
        #expect(!output.contains("\u{07}"))
        #expect(!output.contains("\u{9B}"))
    }

    @Test func markdownStreamsAcrossArbitraryTokenBoundaries() {
        let text = "## Titre\nUn **mot** et `code`.\n```swift\nlet x = 1\n```\nFin"
        var one = TerminalMarkdown(styled: true)
        let expected = one.append(text) + one.finish()
        var split = TerminalMarkdown(styled: true)
        var actual = ""
        for character in text { actual += split.append(String(character)) }
        actual += split.finish()
        #expect(actual == expected)
        #expect(actual.contains("let x = 1"))
        #expect(!actual.contains("**"))
        var streaming = TerminalMarkdown(styled: true)
        #expect(streaming.append("Bonjour") == "Bonjour")
        #expect(streaming.append(" le monde") == " le monde")
    }

    @Test func signalCancelsGenerationAndAllowsNextPrompt() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let service = InterruptibleCLIService()
            try await runGlobalCLI(input: "Premier\nSecond\n/exit\n", service: service)
            #expect(await service.prompts == ["Premier", "Second"])
        }
        let output = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        #expect(output.contains(localizedCLI("console.status.cancelled")))
        #expect(output.contains("Après interruption"))
    }

    @Test(arguments: ["install", "arm", "cancel"])
    func cancellationHandlersCanReenterCancellationState(phase: String) async throws {
        let cancellation = GenerationCancellation()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let reader = Task<Void, Error> {
            try await withTaskCancellationHandler {
                signal.yield(())
                try await Task.sleep(for: .seconds(30))
            } onCancel: {
                #expect(cancellation.isCancelled)
            }
        }
        for await _ in ready { break }
        switch phase {
        case "install":
            cancellation.arm()
            cancellation.cancel()
            cancellation.install(reader)
        case "arm":
            cancellation.cancel()
            cancellation.install(reader)
            cancellation.arm()
        default:
            cancellation.install(reader)
            cancellation.arm()
            cancellation.cancel()
        }
        await #expect(throws: CancellationError.self) { try await reader.value }
    }

    @Test func sensitiveRootsAndAdditionalCredentialNamesAreDenied() throws {
        for name in [".codex", ".ssh", "tokens.json", "passwords.txt", "api_key.txt", ".env.production"] {
            #expect(AuthorizedWorkspace.isSensitive(name: name))
        }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ssh"),
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: NoctisAgent.AgentError.accessDenied) {
            try AuthorizedWorkspace(authorizing: root.appendingPathComponent(".ssh"))
        }
    }
}

private func runGlobalCLI(input: String, service: any AIModelService) async throws {
    let isChild = ExitTest.current != nil
    try #require(isChild)
    let pipe = Pipe()
    try #require(dup2(pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO) >= 0)
    try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try pipe.fileHandleForWriting.close()
    await NoctisApplication(modelService: service).run()
}

private actor InterruptibleCLIService: AIModelService {
    private(set) var prompts: [String] = []
    func load() async throws {}
    func resetConversation(history: [AIChatMessage]) async throws {}
    func cancelGeneration() async {}

    func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        if prompts.count > 1 {
            return AsyncThrowingStream { output in
                output.yield("Après interruption")
                output.finish()
            }
        }
        return AsyncThrowingStream { output in
            let producer = Task {
                output.yield("Réponse partielle")
                try await Task.sleep(for: .milliseconds(100))
                kill(getpid(), SIGINT)
                try await Task.sleep(for: .seconds(10))
                output.finish()
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }

    func withResponse(prompt: String,
                      consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void) async throws {
        try await consume(generate(prompt: prompt))
        try Task.checkCancellation()
    }
}
