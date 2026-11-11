//
//  NoctisApplication.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import Noctis
import NoctisAgent

final class NoctisApplication {

    private let console = ConsoleInterface()
    private let modelService: any AIModelService

    init(modelService: any AIModelService) {
        self.modelService = modelService
    }

    func run() async {
        console.displayWelcome()

        do {
            console.displayStatus(String(localized: "console.status.loading_model",
                                         defaultValue: "Je me prépare pour notre conversation…", bundle: .module))

            try await modelService.load()

            console.displayReady()
            console.displayStatus(String(localized: "console.workspace.hint", defaultValue: "", bundle: .module))
            print()

            await startConversation()

        } catch {
            print(String(localized: "console.error.startup_failed", defaultValue: "Impossible de démarrer Noctis.", bundle: .module, comment: "Message affiché par le CLI."))
            console.displayError(error)
        }

        console.displayStatus(String(localized: "console.status.terminated",
                                     defaultValue: "À bientôt. Prends soin de toi.", bundle: .module))
    }

    private func startConversation() async {
        while let prompt = console.readPrompt() {

            if prompt.lowercased() == NoctisConfiguration.exitCommand {
                break
            }

            guard !prompt.isEmpty else {
                continue
            }

            if await handleWorkspaceCommand(prompt) { continue }
            await generateResponse(for: prompt)
        }
    }

    private func handleWorkspaceCommand(_ prompt: String) async -> Bool {
        guard prompt == "/workspace" || prompt.hasPrefix("/workspace ") else { return false }
        do {
            guard let authorizer = modelService as? any WorkspaceAuthorizing else {
                throw AgentError.unsupportedTool
            }
            let path = String(prompt.dropFirst("/workspace".count)).trimmingCharacters(in: .whitespaces)
            let workspace = path == "off" ? nil
                : try NoctisCLI.authorizedWorkspace(arguments: ["--workspace", path])
            try await authorizer.authorizeWorkspace(workspace)
            print(String(localized: "console.workspace.context_reset",
                         defaultValue: "Contexte réinitialisé pour ce changement d’accès.", bundle: .module))
            if workspace == nil {
                print(String(localized: "console.workspace.revoked", defaultValue: "Accès au dossier révoqué.",
                             bundle: .module))
            } else {
                print(String(localized: "console.workspace.authorized",
                             defaultValue: "Dossier autorisé en lecture seule :", bundle: .module))
                print(path)
            }
        } catch {
            print(String(localized: "console.workspace.invalid",
                         defaultValue: "Dossier refusé. Utilisez /workspace /chemin/absolu sans lien symbolique.",
                         bundle: .module))
        }
        return true
    }

    private func generateResponse(for prompt: String) async {
        do {
            try await modelService.withResponse(prompt: prompt) { [console] stream in
                console.beginResponse()

                for try await chunk in stream {
                    console.displayResponse(chunk)
                }
            }

            print("\n")

        } catch {
            print()
            console.displayError(error)
            print()
        }
    }
}
