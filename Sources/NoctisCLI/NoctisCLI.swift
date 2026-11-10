//
//  NoctisCLI.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Noctis
import NoctisAgent
import Foundation

@main
struct NoctisCLI {

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(usage)
            return
        }
        do {
            if try await runWorkspace(arguments: arguments) { return }
        } catch {
            print(String(localized: "console.workspace.invalid",
                         defaultValue: "Dossier refusé. Utilisez un chemin absolu sans lien symbolique.",
                         bundle: .module))
            print(usage)
            exit(EXIT_FAILURE)
        }
        #if os(macOS)
        let embedded: EmbeddedSearXNGService?
        do {
            if let path = ProcessInfo.processInfo.environment["NOCTIS_SEARXNG_PYTHON"] {
                guard path.hasPrefix("/") else { throw EmbeddedSearXNGError.invalidConfiguration }
                embedded = try EmbeddedSearXNGService(pythonExecutable: URL(fileURLWithPath: path))
            } else {
                embedded = try EmbeddedSearXNGService.bundled() ?? EmbeddedSearXNGService.installed()
            }
        } catch {
            print(error.localizedDescription)
            return
        }
        if embedded != nil {
            print(String(localized: "console.web_search.embedded", defaultValue: "Recherche Web : SearXNG local, démarrage à la demande.", bundle: .module, comment: "Message affiché par le CLI."))
        } else {
            print(String(localized: "console.web_search.external", defaultValue: "Recherche Web : serveur externe attendu sur 127.0.0.1:8888.", bundle: .module, comment: "Message affiché par le CLI."))
            print(String(localized: "console.web_search.setup_hint", defaultValue: "Pour le mode sans Docker : python3 infrastructure/searxng/setup_runtime.py", bundle: .module, comment: "Conserver la commande Python et son chemin tels quels."))
        }
        let modelService = embedded.map { MLXModelService(webSearchService: $0) } ?? MLXModelService()
        #else
        let modelService = MLXModelService()
        #endif
        let application = NoctisApplication(
            modelService: modelService
        )

        await application.run()
        #if os(macOS)
        await embedded?.shutdown()
        #endif
    }

    private static func runWorkspace(arguments: [String]) async throws -> Bool {
        guard let workspace = try authorizedWorkspace(arguments: arguments) else { return false }
        let modelService = MLXModelService()
        try await modelService.authorizeWorkspace(workspace)
        print(String(localized: "console.workspace.authorized",
                     defaultValue: "Dossier autorisé en lecture seule :", bundle: .module))
        print(arguments[1])
        await NoctisApplication(modelService: modelService).run()
        return true
    }

    static var usage: String {
        String(localized: "console.workspace.usage", defaultValue: """
            Utilisation : NoctisCLI [--workspace /chemin/absolu/du/projet]
            Avec --workspace, vous autorisez la lecture de ce dossier. Posez ensuite vos questions normalement.
            Pendant la conversation : /workspace /chemin/absolu pour autoriser un dossier.
            /workspace off retire cet accès.
            Aucun mode code à activer. Tapez exit pour quitter.
            """, bundle: .module)
    }

    /// Supplying --workspace is explicit authorization; no directory is inferred from the current location.
    static func authorizedWorkspace(arguments: [String]) throws -> AuthorizedWorkspace? {
        if arguments.isEmpty { return nil }
        guard arguments.count == 2, arguments[0] == "--workspace",
              arguments[1].hasPrefix("/"), !arguments[1].contains("\0") else {
            throw AgentError.invalidArguments
        }
        return try AuthorizedWorkspace(authorizing: URL(fileURLWithPath: arguments[1]))
    }

}
