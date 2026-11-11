//
//  ConsoleInterface.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Darwin
import Foundation

struct ConsoleInterface {
    let usesColor = isatty(STDOUT_FILENO) == 1
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
        print("  " + styled(TerminalMarkdown.sanitized(message), color: "2"))
    }

    func confirmWorkspace(_ path: String, input: inout ConsoleInput) -> Bool {
        // A model cannot answer this question: only an interactive terminal can grant access.
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            print(String(localized: "console.workspace.explicit_flag", defaultValue:
                "Hors terminal interactif, autorise le dossier au lancement avec --workspace.", bundle: .module))
            return false
        }
        print(TerminalMarkdown.sanitized(path))
        print(String(localized: "console.workspace.confirm", defaultValue:
            "Autoriser la lecture de ce dossier ? [y/o] Autoriser · [n] Refuser", bundle: .module))
        guard let answer = input.readPrompt()?.lowercased() else { return false }
        return ["y", "yes", "o", "oui"].contains(answer)
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
        let details = TerminalMarkdown.sanitized(error.localizedDescription)
        print(String(localized: "console.error.details", defaultValue: "Erreur : \(details)",
                     bundle: .module, comment: "Le paramètre contient la description localisée de l’erreur."))
    }

    private func styled(_ text: String, color: String) -> String {
        usesColor ? "\u{001B}[\(color)m\(text)\u{001B}[0m" : text
    }
}
