//
//  NoctisApplication.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import MLXLMCommon
import MLXVLM
import HuggingFace
import Tokenizers
import MLXHuggingFace

final class NoctisApplication {

    private let modelService: any AIModelService

    init(modelService: any AIModelService) {
        self.modelService = modelService
    }

    func run() async {
        print("🌙 \(NoctisConfiguration.assistantName)")
        print("Hello, Sebby!")
        print()

        do {
            print("Chargement de Ministral 3...")

            try await modelService.load()

            print("Tout est prêt !")
            print("Tape exit pour quitter.")
            print()

            await startConversation()

        } catch {
            print("Impossible de démarrer Noctis.")
            print("Erreur : \(error.localizedDescription)")
        }

        print("🌑 Noctis terminé")
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
        print("Vous > ", terminator: "")
        fflush(stdout)

        return readLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateResponse(for prompt: String) async {
        do {
            let stream = try await modelService.generate(prompt: prompt)

            print()
            print("Noctis 🌙 > ", terminator: "")
            fflush(stdout)

            for try await chunk in stream {
                print(chunk, terminator: "")
                fflush(stdout)
            }

            print("\n")

        } catch {
            print()
            print("Erreur : \(error.localizedDescription)")
            print()
        }
    }
}
