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

    private let modelService: any AIModelService

    init(modelService: any AIModelService) {
        self.modelService = modelService
    }

    func run() async {
        print("🌙 \(NoctisConfiguration.assistantName)")
        print(String(localized: "console.message.welcome", defaultValue: "Bonjour, Sebby !", bundle: .module, comment: "Message affiché par le CLI."))
        print()

        do {
            print(String(localized: "console.status.loading_model", defaultValue: "Chargement de Ministral 3...", bundle: .module, comment: "Message affiché par le CLI."))

            try await modelService.load()

            print(String(localized: "console.status.ready", defaultValue: "Tout est prêt !", bundle: .module, comment: "Message affiché par le CLI."))
            print(String(localized: "console.workspace.hint", defaultValue: """
                Pour autoriser un projet à tout moment : /workspace /chemin/absolu
                Pour retirer cet accès : /workspace off
                """, bundle: .module))
            print(String(localized: "console.hint.exit", defaultValue: "Tape exit pour quitter.", bundle: .module, comment: "Conserver la commande exit telle quelle."))
            print()

            await startConversation()

        } catch {
            print(String(localized: "console.error.startup_failed", defaultValue: "Impossible de démarrer Noctis.", bundle: .module, comment: "Message affiché par le CLI."))
            print(String(localized: "console.error.details", defaultValue: "Erreur : \(error.localizedDescription)", bundle: .module, comment: "Le paramètre contient la description localisée de l’erreur."))
        }

        print(String(localized: "console.status.terminated", defaultValue: "🌑 Noctis terminé", bundle: .module, comment: "Message affiché par le CLI."))
    }

    private func startConversation() async {
        while let prompt = readPrompt() {

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

    private func readPrompt() -> String? {
        print(String(localized: "console.prompt.user", defaultValue: "Vous > ", bundle: .module, comment: "Message affiché par le CLI."), terminator: "")
        fflush(stdout)

        return readLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            try await modelService.withResponse(prompt: prompt) { stream in
                print()
                print("Noctis 🌙 > ", terminator: "")
                fflush(stdout)

                for try await chunk in stream {
                    print(chunk, terminator: "")
                    fflush(stdout)
                }
            }

            print("\n")

        } catch {
            print()
            print(String(localized: "console.error.details", defaultValue: "Erreur : \(error.localizedDescription)", bundle: .module, comment: "Le paramètre contient la description localisée de l’erreur."))
            print()
        }
    }
}
