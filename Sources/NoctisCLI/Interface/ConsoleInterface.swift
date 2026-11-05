//
//  ConsoleInterface.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Foundation

struct ConsoleInterface {

    func displayWelcome() {
        print("🌙 Noctis")
        print(String(localized: "console.message.welcome", defaultValue: "Bonjour, Sebby !", bundle: .module, comment: "Message affiché par le CLI."))
        print()
    }

    func displayReady() {
        print(String(localized: "console.status.ready", defaultValue: "Tout est prêt !", bundle: .module, comment: "Message affiché par le CLI."))
        print(String(localized: "console.hint.exit", defaultValue: "Tape exit pour quitter.", bundle: .module, comment: "Conserver la commande exit telle quelle."))
        print()
    }

    func readPrompt() -> String? {
        print(String(localized: "console.prompt.user", defaultValue: "Vous > ", bundle: .module, comment: "Message affiché par le CLI."), terminator: "")
        fflush(stdout)

        return readLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func displayResponse(_ chunk: String) {
        print(chunk, terminator: "")
        fflush(stdout)
    }

    func displayError(_ error: Error) {
        print(String(localized: "console.error.details", defaultValue: "Erreur : \(error.localizedDescription)", bundle: .module, comment: "Le paramètre contient la description localisée de l’erreur."))
    }
}