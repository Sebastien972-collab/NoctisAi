//
//  ConsoleInterface.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Darwin
import Foundation

struct ConsoleInterface {
    private let usesColor = isatty(STDOUT_FILENO) == 1
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"

    func displayWelcome() {
        print()
        print(styled("  ✦ Noctis", color: "1;33"))
        print("  " + styled(String(localized: "console.identity.subtitle",
                                  defaultValue: "Assistant personnel · IA locale", bundle: .module), color: "2"))
        print()
        print("  " + String(localized: "console.message.welcome", defaultValue: "Bonjour, installe-toi.",
                            bundle: .module, comment: "Message affiché par le CLI."))
        print()
    }

    func displayReady() {
        print("  " + String(localized: "console.status.ready", defaultValue: "Je suis là. Comment puis-je t’aider ?",
                            bundle: .module, comment: "Message affiché par le CLI."))
        print("  " + styled(String(localized: "console.hint.exit", defaultValue: "Tape exit pour quitter.",
                                   bundle: .module, comment: "Conserver la commande exit telle quelle."), color: "2"))
        print()
    }

    func displayStatus(_ message: String) {
        print("  " + styled(message, color: "2"))
    }

    func readPrompt() -> String? {
        print(styled("  › ", color: "33"), terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func beginResponse() {
        print()
        print(styled("  ✦ Noctis", color: "33"))
        print()
        fflush(stdout)
    }

    func displayResponse(_ chunk: String) {
        print(chunk, terminator: "")
        fflush(stdout)
    }

    func displayError(_ error: Error) {
        print(String(localized: "console.error.details", defaultValue: "Erreur : \(error.localizedDescription)",
                     bundle: .module, comment: "Le paramètre contient la description localisée de l’erreur."))
    }

    private func styled(_ text: String, color: String) -> String {
        usesColor ? "\u{001B}[\(color)m\(text)\u{001B}[0m" : text
    }
}
