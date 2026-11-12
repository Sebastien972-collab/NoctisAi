
//
// NoctisToolRegistry.swift
// Noctis
//
// Created by Sébastien DAGUIN.
//

import Foundation
import MLXLMCommon
import NoctisAgent

/// One immutable capability snapshot drives instructions,
/// MLX schemas and dispatch per turn.
struct NoctisToolRegistry: Sendable {

    struct Entry: Sendable {
        let name: String
        let description: String
        let usage: String
        let schema: ToolSpec
    }

    let entries: [Entry]
    let workspace: ToolRegistry?
    let hasWorkspace: Bool

    init(
        workspace: ToolRegistry? = nil,
        allowsWebOpen: Bool = true
    ) {
        self.workspace = workspace
        hasWorkspace = workspace != nil

        if let workspace {
            entries = Self.workspaceEntries(workspace.schemas)
        } else {
            var webEntries = [
                Self.entry(
                    schema: WebSearchTool.schema,
                    usage: """
                    Pour une information récente, vérifier un fait
                    ou trouver une source.

                    Permission réseau de la session.
                    SearXNG configuré, disponibilité non garantie.

                    Requête limitée à 300 caractères / 1200 octets.
                    Maximum 5 résultats.

                    Les extraits ne constituent pas une lecture
                    intégrale de page.

                    Ne pas envoyer de contenu local.
                    """
                )
            ]

            if allowsWebOpen && PinnedHTTPClient.isAvailable {
                webEntries.append(
                    Self.entry(
                        schema: WebOpenTool.schema,
                        usage: """
                        Pour lire, résumer, traduire ou vérifier
                        une page demandée par l'utilisateur.

                        Permission réseau uniquement.
                        Aucun accès au dossier local.

                        URL fournie par l'utilisateur ou issue
                        d'une recherche du même tour.

                        Les liens contenus dans une page
                        n'autorisent aucune nouvelle consultation.

                        HTTPS public sur le port 443.
                        Certificat TLS valide.
                        Aucune redirection ni ressource secondaire.

                        Maximum deux consultations simultanées
                        et quatre ouvertures par tour.

                        Limites : 2 Mio reçus,
                        20 000 caractères extraits
                        et 64 Kio de texte retourné.

                        Signale les erreurs et troncatures.

                        N'invente aucun contenu manquant.
                        Ne prétends pas avoir consulté une page
                        si l'appel échoue.
                        """
                    )
                )
            }

            entries = webEntries
        }
    }

    /// The agent runtime supplies only its permitted tools.
    /// Web capabilities are not exposed in workspace mode.
    init(agentTools: [AgentToolSchema]) {
        workspace = nil
        hasWorkspace = true
        entries = Self.workspaceEntries(agentTools)
    }

    var schemas: [ToolSpec] {
        entries.map(\.schema)
    }

    func permits(_ name: String) -> Bool {
        entries.contains { $0.name == name }
    }

    private static func workspaceEntries(
        _ tools: [AgentToolSchema]
    ) -> [Entry] {
        MLXModelService.agentSchemas(tools).map {
            entry(
                schema: $0,
                usage: """
                Uniquement si la demande nécessite
                de consulter le dossier autorisé par l'hôte.

                Lecture seule et chemins relatifs.

                Fichiers sensibles, liens et sorties
                de périmètre refusés.

                Aucun parcours automatique pour une salutation
                ou une question générale.

                Appels, lectures, recherches et résultats
                bornés par le runtime.

                Les erreurs et troncatures doivent être signalées.

                Aucun accès réseau dans ce contexte.
                """
            )
        }
    }

    private static func entry(
        schema: ToolSpec,
        usage: String
    ) -> Entry {
        let function = schema["function"]
            as? [String: any Sendable] ?? [:]

        return Entry(
            name: function["name"] as? String ?? "",
            description: function["description"] as? String ?? "",
            usage: usage,
            schema: schema
        )
    }
}

// MARK: - Tool Dispatcher

actor NoctisToolDispatcher {

    private let registry: NoctisToolRegistry
    private let local: ConversationToolDispatcher?
    private let web: WebToolDispatcher

    private var remainingCalls = 8
    private var remainingOpens = 4

    private var pageURLs: Set<String>

    init(
        registry: NoctisToolRegistry,
        web: WebToolDispatcher,
        userPrompt: String = ""
    ) {
        self.registry = registry
        self.web = web

        local = registry.workspace.map {
            ConversationToolDispatcher(registry: $0)
        }

        pageURLs = Self.userURLs(userPrompt)
    }

    func execute(
        _ call: MLXLMCommon.ToolCall
    ) async throws -> String {
        try Task.checkCancellation()

        guard registry.permits(call.function.name) else {
            throw WebToolError.unsupportedTool("unsupported")
        }

        guard remainingCalls > 0 else {
            throw AgentError.iterationLimit
        }

        // MARK: Local tools

        if let local {
            remainingCalls -= 1

            let output = try await local.execute(call)

            // Preserve AgentRunKit error propagation.
            if let data = output.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(
                   with: data
               ) as? [String: String],
               object.count == 1,
               let code = object["error"],
               let error = NoctisAgent.AgentError(rawValue: code) {
                throw error
            }

            return output
        }

        // MARK: Web authorization

        if call.function.name == WebOpenTool.name {
            let url = try WebOpenTool.validate(call)

            guard pageURLs.contains(url.absoluteString) else {
                throw WebToolError.pageNotAuthorized
            }

            guard remainingOpens > 0 else {
                throw WebPageError.requestLimit
            }

            remainingOpens -= 1
        }

        remainingCalls -= 1

        // MARK: Web execution

        let output = try await web.execute(call)

        // Authorize only URLs returned by a successful
        // web_search call in the current turn.
        if call.function.name == WebSearchTool.name,
           let data = output.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(
               SearchPageURLs.self,
               from: data
           ) {
            for result in envelope.results.prefix(5) {
                if let url = try? PublicWebURLPolicy.validate(
                    result.url
                ) {
                    pageURLs.insert(url.absoluteString)
                }
            }
        }

        return output
    }

    // MARK: - Search Result Models

    private struct SearchPageURL: Decodable {
        let url: String
    }

    private struct SearchPageURLs: Decodable {
        let results: [SearchPageURL]
    }

    // MARK: - User Authorized URLs

    private static func userURLs(
        _ prompt: String
    ) -> Set<String> {
        guard prompt.utf8.count <= 65_536,
              let detector = try? NSDataDetector(
                  types: NSTextCheckingResult.CheckingType.link.rawValue
              ) else {
            return []
        }

        let range = NSRange(
            prompt.startIndex..<prompt.endIndex,
            in: prompt
        )

        let matches = detector.matches(
            in: prompt,
            range: range
        )

        return Set(
            matches.prefix(32).compactMap { match in
                guard let raw = match.url?.absoluteString,
                      let url = try? PublicWebURLPolicy.validate(
                          raw
                      ) else {
                    return nil
                }

                return url.absoluteString
            }
        )
    }
}
