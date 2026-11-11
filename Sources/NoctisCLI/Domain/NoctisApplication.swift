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
    private var input = ConsoleInput()
    private var workspace: AuthorizedWorkspace?
    private var loaded = false

    init(modelService: any AIModelService, workspace: AuthorizedWorkspace? = nil) {
        self.modelService = modelService
        self.workspace = workspace
    }

    func run() async {
        let interrupts = ConsoleInterrupts()
        defer { interrupts.stop() }
        console.displayWelcome()
        console.displayReady()
        while let prompt = input.readPrompt() {
            if [NoctisConfiguration.exitCommand, "/exit"].contains(prompt.lowercased()) { break }
            guard !prompt.isEmpty else { continue }
            if await handleCommand(prompt) { continue }
            await respond(to: prompt, interrupts: interrupts)
        }
        console.displayStatus(String(localized: "console.status.terminated",
                                     defaultValue: "À bientôt. Prends soin de toi.", bundle: .module))
    }

    private func respond(to prompt: String, interrupts: ConsoleInterrupts) async {
        defer { interrupts.install(nil) }
        do {
            if !loaded {
                console.displayStatus(String(localized: "console.status.loading_model",
                    defaultValue: "Je me prépare pour notre conversation…", bundle: .module))
                let model = modelService
                let load = Task { try await model.load() }
                interrupts.install { load.cancel() }
                try await load.value
                loaded = true
                try Task.checkCancellation()
            }
            let model = modelService
            let console = console
            let generation = Task {
                console.beginResponse()
                try await model.withResponse(prompt: prompt) { stream in
                    var renderer = TerminalMarkdown(styled: console.usesColor)
                    do {
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            console.displayResponse(renderer.append(chunk))
                        }
                    } catch {
                        console.displayResponse(renderer.finish())
                        throw error
                    }
                    console.displayResponse(renderer.finish())
                }
                try Task.checkCancellation()
                print("\n")
            }
            interrupts.install { generation.cancel() }
            try await generation.value
        } catch is CancellationError {
            await modelService.cancelGeneration()
            print()
            console.displayStatus(String(localized: "console.status.cancelled",
                defaultValue: "Réponse interrompue. On peut continuer.", bundle: .module))
        } catch {
            if !loaded {
                console.displayStatus(String(localized: "console.error.startup_failed",
                    defaultValue: "Impossible de démarrer Noctis.", bundle: .module))
            }
            print()
            console.displayError(error)
            print()
        }
    }

    private func handleCommand(_ prompt: String) async -> Bool {
        switch prompt {
        case "/help": print(NoctisCLI.interactiveHelp)
        case "/model": print(NoctisConfiguration.modelID)
        case "/permissions":
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
                input = ConsoleInput()
                console.displayStatus(String(localized: "console.history.cleared",
                                             defaultValue: "Une nouvelle conversation commence.", bundle: .module))
            } catch { console.displayError(error) }
        default:
            if prompt.hasPrefix("/workspace ") {
                await changeWorkspace(String(prompt.dropFirst("/workspace ".count)))
            } else if prompt.hasPrefix("/") {
                print(NoctisCLI.interactiveHelp)
            } else { return false }
        }
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
            workspace = next
            console.displayStatus(String(localized: "console.workspace.context_reset",
                defaultValue: "Contexte réinitialisé pour ce changement d’accès.", bundle: .module))
            print(next.map { TerminalMarkdown.sanitized($0.path) } ?? String(localized: "console.workspace.revoked",
                                      defaultValue: "Accès au dossier révoqué.", bundle: .module))
        } catch {
            console.displayStatus(String(localized: "console.workspace.invalid",
                                         defaultValue: "Dossier refusé. Utilise un chemin absolu sans lien symbolique.",
                                         bundle: .module))
        }
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
