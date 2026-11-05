//
//  NoctisApplication.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import Noctis

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

            await generateResponse(for: prompt)
        }
    }

    private func readPrompt() -> String? {
        print(String(localized: "console.prompt.user", defaultValue: "Vous > ", bundle: .module, comment: "Message affiché par le CLI."), terminator: "")
        fflush(stdout)

        return readLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
