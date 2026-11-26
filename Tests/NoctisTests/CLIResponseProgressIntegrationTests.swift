// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon
import NoctisAgent
import Testing
@testable import Noctis
@testable import NoctisCLI

@Suite("CLI response progress integration", .timeLimit(.minutes(1)))
struct CLIResponseProgressIntegrationTests {
    @Test func waitingIsVisibleBeforeADelayedProviderProducesItsFirstToken() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let capture = ResponseProgressCapture()
            let progress = CLIResponseProgress(animated: false, output: { capture.append($0) })
            let service = DelayedProgressService {
                #expect(capture.read().contains(localizedCLI("console.progress.waiting")))
            }
            let application = NoctisApplication(modelService: service, progressFactory: { progress })
            #expect(await application.runOnce(prompt: "Bonjour"))
            #expect(capture.read().contains(localizedCLI("console.progress.downloading")))
            #expect(capture.read().contains(localizedCLI("console.progress.loading")))
            let complete = capture.read()
            progress.tick()
            #expect(capture.read() == complete)
        }
        let output = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        #expect(output.contains("FIRST_VISIBLE_TEXT"))
        #expect(!output.contains(localizedCLI("console.progress.waiting")))
    }

    @Test func actualToolCompletionRestartsWaitingAndKeepsPrivateAnalysisHidden() async throws {
        let result = try await #require(processExitsWith: .success,
                                       observing: [\.standardOutputContent, \.standardErrorContent]) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = try AuthorizedWorkspace(authorizing: directory.resolvingSymlinksInPath())
            let probe = ScriptProbe([
                [.call("listFiles", "list00001", ["path": .string(".")])],
                [.generation(.reasoning("PRIVATE_ANALYSIS")), .text("FINAL_ANSWER")]
            ])
            let model = MLXModelService(sessionFactory: { _ in ScriptSession(probe, profile: .gptOSS) })
            try await model.authorizeWorkspace(workspace)
            #expect(await NoctisApplication(modelService: model, workspace: workspace).runOnce(prompt: "Liste"))
        }
        let output = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        let errors = try #require(String(bytes: result.standardErrorContent, encoding: .utf8))
        #expect(output.contains("Liste des fichiers…"))
        #expect(output.contains("FINAL_ANSWER"))
        #expect(errors.components(separatedBy: localizedCLI("console.progress.waiting")).count == 3)
        #expect(!errors.contains("\u{1B}"))
        #expect(!(output + errors).contains("PRIVATE_ANALYSIS"))
    }

    @Test func cancellationReportsCleanupBeforeAwaitingIt() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let service = DelayedProgressService(cancelBeforeText: true, inspectBeforeText: {})
            #expect(await NoctisApplication(modelService: service).runOnce(prompt: "Bonjour") == false)
        }
        let output = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        let pending = try #require(output.range(of: localizedCLI("console.progress.cancelling")))
        let cleanup = try #require(output.range(of: "CLEANUP_STARTED"))
        let completed = try #require(output.range(of: localizedCLI("console.status.cancelled")))
        #expect(pending.lowerBound < cleanup.lowerBound)
        #expect(cleanup.lowerBound < completed.lowerBound)
    }
}

private struct DelayedProgressService: AIModelService {
    var cancelBeforeText = false
    let inspectBeforeText: @Sendable () -> Void
    func load() async throws {}
    func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws {
        progress(.downloading)
        progress(.loading)
        progress(.ready)
    }
    func resetConversation(history: [AIChatMessage]) async throws {}
    func cancelGeneration() async {
        if cancelBeforeText {
            print("CLEANUP_STARTED")
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
    func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        inspectBeforeText()
        try await Task.sleep(for: .milliseconds(150))
        inspectBeforeText()
        if cancelBeforeText { throw CancellationError() }
        return AsyncThrowingStream { output in
            output.yield("FIRST_VISIBLE_TEXT")
            output.finish()
        }
    }
    func withResponse(prompt: String,
                      consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void) async throws {
        try await consume(generate(prompt: prompt))
    }
}
