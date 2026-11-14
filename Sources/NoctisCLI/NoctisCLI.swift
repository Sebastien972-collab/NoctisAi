//
//  NoctisCLI.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Darwin
import Foundation
import Noctis
import NoctisAgent

@main
struct NoctisCLI {
    enum Command: Equatable {
        case chat(String?), task(String, String?), toolsDoctor, help, version, doctor, update
        case updateMode(CLIUpdateMode)
    }

    static func command(arguments: [String]) throws -> Command {
        if let task = directTask(arguments) { return task }
        return try maintenanceCommand(arguments)
    }

    private static func directTask(_ arguments: [String]) -> Command? {
        switch arguments {
        case ["review"]:
            return .task(
                "Analyse le workspace autorisé en lecture seule. Identifie les bugs et risques, avec chemins et preuves.",
                FileManager.default.currentDirectoryPath
            )
        case ["search", let query] where !query.isEmpty:
            return .task(
                "Utilise web_search pour rechercher : \(query). Cite les URL effectivement retournées.",
                nil
            )
        case ["summarize", let url] where url.hasPrefix("https://"):
            return .task(
                "Utilise web_open pour lire et résumer cette page, et signale les troncatures : \(url)",
                nil
            )
        case ["ask", let question] where !question.isEmpty:
            return .task(question, nil)
        case ["explain", let path] where !path.isEmpty && !path.hasPrefix("/"):
            return .task(
                "Lis puis explique ce fichier relatif au workspace : \(path). Ne suppose aucun contenu.",
                FileManager.default.currentDirectoryPath
            )
        default:
            return nil
        }
    }

    private static func maintenanceCommand(_ arguments: [String]) throws -> Command {
        switch arguments {
        case []: return .chat(nil)
        case ["--help"], ["-h"]: return .help
        case ["--version"]: return .version
        case ["doctor"]: return .doctor
        case ["update"]: return .update
        case ["update", "--check"]: return .updateMode(.check)
        case ["update", "--dev"]: return .updateMode(.development)
        case ["update", "--rollback"]: return .updateMode(.rollback)
        case ["tools", "doctor"]: return .toolsDoctor
        default:
            return try workspaceCommand(arguments)
        }
    }

    private static func workspaceCommand(_ arguments: [String]) throws -> Command {
        guard arguments.count == 2, arguments[0] == "--workspace",
              arguments[1].hasPrefix("/"), !arguments[1].contains("\0") else {
            throw NoctisAgent.AgentError.invalidArguments
        }
        return .chat(arguments[1])
    }

    static func main() async {
        do {
            let parsed = try command(arguments: Array(CommandLine.arguments.dropFirst()))
            try await execute(parsed)
        } catch {
            ConsoleInterface().displayError(error)
            print(usage)
            exit(EXIT_FAILURE)
        }
    }

    private static func execute(_ command: Command) async throws {
        switch command {
        case .help: print(usage)
        case .version: print(CLIBuildIdentity.installed.display)
        case .doctor:
            if !doctor() { exit(EXIT_FAILURE) }
        case .toolsDoctor:
            print("Web : disponible sans workspace ; vérifier SearXNG avec une recherche réelle.")
            print("Fichiers : autorisation explicite du workspace nécessaire.")
            if !doctor() { exit(EXIT_FAILURE) }
        case .task(let prompt, let path):
            try await oneShot(prompt: prompt, workspacePath: path)
        case .update: try await update(.stable)
        case .updateMode(let mode): try await update(mode)
        case .chat(let path): try await chat(workspacePath: path)
        }
    }

    private static func oneShot(prompt: String, workspacePath: String?) async throws {
        let workspace = try workspacePath.map {
            try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: $0))
        }
        let model = MLXModelService(presentation: .plainText)
        try await model.authorizeWorkspace(workspace)
        let success = await NoctisApplication(modelService: model, workspace: workspace).runOnce(prompt: prompt)
        if !success { exit(EXIT_FAILURE) }
    }

    private static func chat(workspacePath: String?) async throws {
        let console = ConsoleInterface()
        let workspace: AuthorizedWorkspace?
        if let workspacePath {
            workspace = try authorizedWorkspace(arguments: ["--workspace", workspacePath])
        } else {
            // Default to Web-capable conversation. Local file access is opt-in
            // via --workspace or the interactive /workspace command.
            workspace = nil
        }
        let embedded: EmbeddedSearXNGService?
        do {
            if let path = ProcessInfo.processInfo.environment["NOCTIS_SEARXNG_PYTHON"] {
                guard path.hasPrefix("/") else { throw EmbeddedSearXNGError.invalidConfiguration }
                embedded = try EmbeddedSearXNGService(pythonExecutable: URL(fileURLWithPath: path))
            } else {
                embedded = try EmbeddedSearXNGService.bundled() ?? EmbeddedSearXNGService.installed()
            }
        } catch {
            // Optional Web capabilities must never prevent a local conversation.
            embedded = nil
            console.displayError(error)
        }
        let model = embedded.map { MLXModelService(webSearchService: $0, presentation: .plainText) }
            ?? MLXModelService(presentation: .plainText)
        try await model.authorizeWorkspace(workspace)
        await NoctisApplication(modelService: model, workspace: workspace).run()
        await embedded?.shutdown()
    }

    static var executableDirectory: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
    }

    static var version: String {
        CLIBuildIdentity.installed.version
    }

    @discardableResult
    static func doctor() -> Bool {
        print(CLIBuildIdentity.installed.display)
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print(TerminalMarkdown.sanitized(executableDirectory.path))
        #if arch(arm64)
        print("Apple Silicon : OK")
        #else
        print("MLX : Apple Silicon requis.")
        return false
        #endif
        var valid = true
        for name in ["Noctis_NoctisCLI.bundle", "Noctis_Noctis.bundle",
                     "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"] {
            let exists = FileManager.default.fileExists(atPath: executableDirectory.appendingPathComponent(name).path)
            print("\(exists ? "✓" : "✗") \(name)")
            valid = valid && exists
        }
        print(String(localized: "console.doctor.summary", defaultValue: """
            Diagnostic sans chargement ni téléchargement du modèle.
            Recherche Web optionnelle : runtime SearXNG local ou serveur sur 127.0.0.1:8888.
            Pour les commandes de compilation : Xcode, Swift 6.4 et le composant Metal sont requis.
            """, bundle: .module))
        return valid
    }

    static var usage: String {
        String(localized: "console.cli.usage", defaultValue: """
            Utilisation : noctis [--workspace /chemin/absolu]
              noctis --help       Afficher cette aide
              noctis --version    Afficher la version installée
              noctis doctor       Vérifier l’installation sans charger le modèle
              noctis update       Installer la dernière version stable vérifiée
              noctis update --check      Vérifier sans installer
              noctis update --dev        Compiler main après confirmation
              noctis update --rollback   Restaurer la version précédente

            Le dossier courant n'est pas autorisé par défaut.
            noctis search "termes"       Recherche Web ponctuelle
            noctis summarize https://...  Résumé d'une page HTTPS
            noctis ask "question"        Réponse ponctuelle
            noctis review                Revue du dossier courant (lecture seule)
            noctis explain fichier.swift Explication d'un fichier
            noctis tools doctor          Diagnostic des outils
            Le modèle est chargé à la première question uniquement.
            """, bundle: .module) + "\n\n" + interactiveHelp
    }

    static var interactiveHelp: String {
        String(localized: "console.cli.interactive_help", defaultValue: """
            /help          Aide
            /clear         Effacer le contexte et l’historique de saisie
            /model         Afficher le modèle actif
            /workspace     Afficher le dossier autorisé
            /workspace /chemin/absolu   Changer de dossier après confirmation
            /workspace off            Retirer l’accès local et retrouver la recherche Web
            /permissions   Afficher les autorisations et limites
            /exit          Quitter (exit et Ctrl+D fonctionnent aussi)

            Termine une ligne par \\ pour continuer sur la suivante.
            Flèches ↑/↓ : historique de session · Ctrl+U : effacer la ligne
            Ctrl+C : abandonner la saisie ou interrompre la réponse.
            Les écritures et commandes système restent désactivées.
            """, bundle: .module)
    }

    /// An explicit flag authorizes its absolute path; interactive scope changes require separate confirmation.
    static func authorizedWorkspace(arguments: [String]) throws -> AuthorizedWorkspace? {
        if arguments.isEmpty { return nil }
        guard case .chat(let path) = try command(arguments: arguments), let path else {
            throw NoctisAgent.AgentError.invalidArguments
        }
        return try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: path))
    }
}
