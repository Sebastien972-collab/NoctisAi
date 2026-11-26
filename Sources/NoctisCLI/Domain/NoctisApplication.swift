//
//  NoctisApplication.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Darwin
import Foundation
import Noctis
import NoctisAgent
import os

final class NoctisApplication {
    private let console = ConsoleInterface()
    private let modelService: any AIModelService
    private let progressFactory: @Sendable () -> CLIResponseProgress
    private var input = ConsoleInput()
    private var workspace: AuthorizedWorkspace?
    private var loaded = false
    private var agentHistory: [ChatMessage] = []
    private var cliAgent: NoctisCLIAgent?

    init(modelService: any AIModelService, workspace: AuthorizedWorkspace? = nil,
         progressFactory: @escaping @Sendable () -> CLIResponseProgress = { CLIResponseProgress() }) {
        self.modelService = modelService
        self.workspace = workspace
        self.progressFactory = progressFactory
    }

    /// Execute one task and return to the shell without opening an input loop.
    func runOnce(prompt: String) async -> Bool {
        let interrupts = ConsoleInterrupts()
        defer { interrupts.stop() }
        let succeeded = await respond(to: prompt, interrupts: interrupts)
        cliAgent?.endSession()
        return succeeded
    }

    func run() async {
        let interrupts = ConsoleInterrupts()
        defer { interrupts.stop() }
        console.displayWelcome()
        console.displayReady()
        while let prompt = input.readPrompt() {
            if [NoctisConfiguration.exitCommand, "/exit"].contains(prompt.lowercased()) { break }
            guard !prompt.isEmpty else { continue }
            if await handleCommand(prompt) { fflush(stdout); continue }
            await respond(to: prompt, interrupts: interrupts)
        }
        cliAgent?.endSession()
        console.displayStatus(String(localized: "console.status.terminated",
                                     defaultValue: "À bientôt. Prends soin de toi.", bundle: .module))
    }

    @discardableResult
    private func respond(to prompt: String, interrupts: ConsoleInterrupts) async -> Bool {
        defer { interrupts.install(nil) }
        let progress = progressFactory()
        do {
            let history = try await progress.track {
                try await prepareModel(interrupts: interrupts, progress: progress)
                let model = modelService
                let console = console
                let currentAgent = cliAgent
                let currentHistory = agentHistory
                let generation = Task {
                    if let agent = currentAgent {
                        return try await Self.renderAgent(agent, prompt: prompt, history: currentHistory,
                                                          console: console, progress: progress)
                    }
                    try await Self.renderPlainResponse(model: model, prompt: prompt,
                                                       console: console, progress: progress)
                    return nil
                }
                interrupts.install { generation.cancel() }
                return try await generation.value
            }
            if let history { agentHistory = history }
            return true
        } catch is CancellationError {
            print()
            console.displayStatus(String(localized: "console.progress.cancelling",
                                         defaultValue: "Interruption en cours…", bundle: .module))
            if let history = await cliAgent?.settledHistory() { agentHistory = history }
            await modelService.cancelGeneration()
            console.displayStatus(String(localized: "console.status.cancelled",
                                         defaultValue: "Réponse interrompue. On peut continuer.", bundle: .module))
            return false
        } catch {
            if let history = await cliAgent?.settledHistory() { agentHistory = history }
            if !loaded {
                console.displayStatus(String(localized: "console.error.startup_failed",
                                             defaultValue: "Impossible de démarrer Noctis.", bundle: .module))
            }
            print()
            console.displayError(error)
            print()
            return false
        }
    }

    private func prepareModel(interrupts: ConsoleInterrupts, progress: CLIResponseProgress) async throws {
        if !loaded {
            progress.update(.loading)
            let model = modelService
            let load = Task { try await model.load(progress: { progress.loading($0) }) }
            interrupts.install { load.cancel() }
            try await load.value
            loaded = true
            if let mlx = modelService as? MLXModelService {
                cliAgent = try await mlx.makeNoctisCLIAgent()
            }
            try Task.checkCancellation()
        }
    }

    private static func renderAgent(
        _ agent: NoctisCLIAgent,
        prompt: String,
        history: [ChatMessage],
        console: ConsoleInterface,
        progress: CLIResponseProgress
    ) async throws -> [ChatMessage]? {
        console.beginResponse()
        progress.update(.waiting)
        var renderer = TerminalMarkdown(styled: console.usesColor)
        var nextHistory: [ChatMessage]?
        var streamedText = ""
        do {
            for try await event in agent.stream(prompt: prompt, history: history) {
                try Task.checkCancellation()
                switch event.kind {
                case .delta(let text):
                    streamedText += text
                    let rendered = renderer.append(text)
                    if !rendered.isEmpty { progress.pause(); console.displayResponse(rendered) }
                case .toolCallStarted(let name, _) where name != "finish":
                    progress.pause()
                    streamedText = ""
                    console.displayResponse(renderer.finish())
                    renderer = TerminalMarkdown(styled: console.usesColor)
                    print()
                    console.displayStatus(toolAction(name))
                case .toolCallCompleted(_, let name, let result) where name != "finish":
                    presentToolCompletion(result, console: console, progress: progress)
                case .finished(_, let content, let reason, let history):
                    progress.pause()
                    nextHistory = presentCompletion(content: content, reason: reason, history: history,
                                                    renderer: &renderer, streamed: streamedText, console: console)
                default:
                    continue
                }
            }
            progress.pause()
            console.displayResponse(renderer.finish())
            print("\n")
            try Task.checkCancellation()
            return nextHistory
        } catch {
            progress.pause()
            console.displayResponse(renderer.finish())
            throw error
        }
    }

    // Completion content may arrive without text deltas when the model uses finish.
    // Keep the existing explicit execution contract without an unrelated API change.
    // swiftlint:disable:next function_parameter_count
    private static func presentCompletion(content: String?, reason: FinishReason?, history: [ChatMessage],
                                          renderer: inout TerminalMarkdown, streamed: String,
                                          console: ConsoleInterface) -> [ChatMessage] {
        var nextHistory = history
        if let content {
            console.displayResponse(renderer.append(Self.finalSuffix(content, streamed: streamed)))
        }
        if reason != .completed {
            console.displayResponse(renderer.finish())
            renderer = TerminalMarkdown(styled: console.usesColor)
            print()
            console.displayStatus(completionStatus(reason))
            if case .assistant(let message) = nextHistory.last, message.toolCalls.isEmpty {
                // The assistant already closes this turn.
            } else {
                nextHistory.append(.assistant(AssistantMessage(content: "Tâche interrompue avant la fin.")))
            }
        }
        return nextHistory
    }

    private static func completionStatus(_ reason: FinishReason?) -> String {
        switch reason {
        case .maxIterationsReached: MLXModelServiceError.toolLimit.localizedDescription
        case .tokenBudgetExceeded: MLXModelServiceError.contextLimit.localizedDescription
        default:
            String(localized: "console.status.incomplete_response", defaultValue: "La tâche reste incomplète.",
                   bundle: .module)
        }
    }

    static func finalSuffix(_ content: String, streamed: String) -> String {
        if content.hasPrefix(streamed) { return String(content.dropFirst(streamed.count)) }
        return streamed.isEmpty ? content : "\n" + content
    }

    private func handleCommand(_ prompt: String) async -> Bool {
        switch prompt {
        case "/help": print(NoctisCLI.interactiveHelp)
        case "/model": print(NoctisConfiguration.modelID)
        case "/diagnostics on", "/diagnostics off":
            cliAgent?.traceRecorder.diagnosticsEnabled = prompt.hasSuffix("on")
        case "/permissions":
            console.displayStatus(workspace == nil
            ? "Aucun accès aux fichiers locaux. Recherche Web autorisée ; disponibilité du service non garantie."
            : "Lecture seule dans le dossier autorisé. Accès réseau désactivé pour ce contexte.")
            console.displayStatus(String(localized: "console.permissions.summary", defaultValue: """
                Lecture limitée au dossier autorisé, uniquement pour répondre à tes demandes.
                Fichiers sensibles, liens symboliques et fichiers de plus de 64 Kio : refusés.
                Écriture et commandes système : désactivées dans cette version.
                Aucun accès local lorsque /workspace off est actif.
                """, bundle: .module))
        case "/workspace":
            print(workspace.map { TerminalMarkdown.sanitized($0.path) } ?? String(localized: "console.workspace.none",
            defaultValue: "Aucun dossier autorisé.", bundle: .module))
        case "/clear":
            do {
                if loaded { try await modelService.resetConversation(history: []) }
                agentHistory = []
                cliAgent?.endSession()
                cliAgent = loaded ? try await (modelService as? MLXModelService)?.makeNoctisCLIAgent() : nil
                input = ConsoleInput()
                console.displayStatus(String(localized: "console.history.cleared",
                                             defaultValue: "Une nouvelle conversation commence.", bundle: .module))
            } catch { console.displayError(error) }
        default:
            return await handleWorkspaceCommand(prompt)
        }
        return true
    }

    private func handleWorkspaceCommand(_ prompt: String) async -> Bool {
        if prompt.hasPrefix("/workspace ") {
            await changeWorkspace(String(prompt.dropFirst("/workspace ".count)))
        } else if prompt.hasPrefix("/") {
            print(NoctisCLI.interactiveHelp)
        } else { return false }
        return true
    }

    private func changeWorkspace(_ path: String) async {
        do {
            guard let authorizer = modelService as? any WorkspaceAuthorizing else { throw AgentError.unsupportedTool }
            let value = path.trimmingCharacters(in: .whitespaces)
            let next = value == "off" ? nil
                : try NoctisCLI.authorizedWorkspace(arguments: ["--workspace", value])
            if let next, !console.confirmWorkspace(next.path, input: &input) { return }
            try await authorizer.authorizeWorkspace(next)
            cliAgent?.endSession()
            cliAgent = loaded ? try await (modelService as? MLXModelService)?.makeNoctisCLIAgent() : nil
            agentHistory = []
            workspace = next
            console.displayStatus(String(localized: "console.workspace.context_reset",
                                         defaultValue: "Contexte réinitialisé pour ce changement d’accès.",
                    bundle: .module))
            print(next.map { TerminalMarkdown.sanitized($0.path) } ?? String(localized: "console.workspace.revoked",
            defaultValue: "Accès au dossier révoqué.", bundle: .module))
        } catch {
            console.displayStatus(String(localized: "console.workspace.invalid",
                                         defaultValue: "Dossier refusé. Utilise un chemin absolu sans lien symbolique.",
                                         bundle: .module))
        }
    }
}

private extension NoctisApplication {
    static func toolAction(_ name: String) -> String {
        switch name {
        case "web_search": "Recherche Web…"
        case "web_open": "Lecture de la page Web…"
        case "readFile": "Lecture du fichier…"
        case "listFiles": "Liste des fichiers…"
        default: "Recherche dans les fichiers…"
        }
    }

    static func presentToolCompletion(_ result: ToolResult, console: ConsoleInterface,
                                      progress: CLIResponseProgress) {
        progress.pause()
        if result.isError {
            print()
            console.displayStatus(result.content == "Action refusée : permission insuffisante"
                                    ? "Action refusée : permission insuffisante" : "Action échouée")
        }
        progress.update(.waiting)
    }

    static func renderPlainResponse(model: any AIModelService, prompt: String, console: ConsoleInterface,
                                    progress: CLIResponseProgress) async throws {
        console.beginResponse()
        progress.update(.waiting)
        try await model.withResponse(prompt: prompt) { stream in
            var renderer = TerminalMarkdown(styled: console.usesColor)
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    let rendered = renderer.append(chunk)
                    if !rendered.isEmpty { progress.pause(); console.displayResponse(rendered) }
                }
            } catch {
                progress.pause()
                console.displayResponse(renderer.finish())
                throw error
            }
            progress.pause()
            console.displayResponse(renderer.finish())
        }
        try Task.checkCancellation()
        print("\n")
    }
}

/// A signal handler never touches MLX or stdio. Cancellation is forwarded from a dispatch queue.
private final class ConsoleInterrupts: Sendable {
    private let action = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let source: any DispatchSourceSignal
    private let previous: sig_t?

    init() {
        previous = signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let action = action
        source.setEventHandler { action.withLock { $0 }?() }
        source.resume()
    }

    func install(_ value: (@Sendable () -> Void)?) { action.withLock { $0 = value } }

    func stop() {
        source.cancel()
        signal(SIGINT, previous)
    }
}
