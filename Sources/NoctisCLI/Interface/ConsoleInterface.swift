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
        print("Hello, Sebby!")
        print()
    }

    func displayReady() {
        print("Tout est prêt !")
        print("Tape exit pour quitter.")
        print()
    }

    func readPrompt() -> String? {
        print("Vous > ", terminator: "")
        fflush(stdout)

        return readLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func displayResponse(_ chunk: String) {
        print(chunk, terminator: "")
        fflush(stdout)
    }

    func displayError(_ error: Error) {
        print("Erreur : \(error.localizedDescription)")
    }
}