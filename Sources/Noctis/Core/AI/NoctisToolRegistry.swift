// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon
import NoctisAgent

/// One immutable capability snapshot drives instructions, MLX schemas and dispatch per turn.
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

    init(workspace: ToolRegistry? = nil, allowsWebOpen: Bool = true) {
        self.workspace = workspace
        hasWorkspace = workspace != nil
        if let workspace {
            entries = Self.workspaceEntries(workspace.schemas)
        } else {
            var webEntries = [Self.entry(schema: WebSearchTool.schema, usage: """
                Pour une information récente, vérifier un fait ou trouver une source.
                Permission réseau de la session ; SearXNG configuré, disponibilité non garantie.
                Une requête de 300 caractères/1200 octets au maximum, 5 résultats au maximum.
                Les extraits ne constituent pas une lecture intégrale de page. Ne pas envoyer de contenu local.
                """)]
            if allowsWebOpen && PinnedHTTPClient.isAvailable {
                webEntries.append(Self.entry(schema: WebOpenTool.schema, usage: """
                    Pour lire, résumer, traduire ou vérifier une page demandée par l'utilisateur.
                    Permission réseau uniquement, aucun dossier local autorisé. URL fournie par l'utilisateur
                    ou issue d'une recherche du même tour ; les liens contenus dans une page n'autorisent rien.
                    HTTPS/443 public, certificat valide, aucune redirection ou ressource secondaire.
                    Deux consultations simultanées et quatre appels par tour au maximum ; 2 Mio reçus,
                    20 000 caractères et 64 Kio de texte retourné. Signale erreurs et troncatures.
                    Résume ou traduis uniquement le texte reçu ; n'invente pas de contenu manquant.
                    Ne prétends pas avoir consulté la page si l'appel échoue.
                    """))
            }
            entries = webEntries
        }
    }

    /// The agent runtime supplies the exact subset it can dispatch, without Web capabilities.
    init(agentTools: [AgentToolSchema]) {
        workspace = nil
        hasWorkspace = true
        entries = Self.workspaceEntries(agentTools)
    }

    var schemas: [ToolSpec] { entries.map(\.schema) }

    func permits(_ name: String) -> Bool { entries.contains { $0.name == name } }

    private static func workspaceEntries(_ tools: [AgentToolSchema]) -> [Entry] {
        MLXModelService.agentSchemas(tools).map {
            entry(schema: $0, usage: """
                Uniquement si la demande nécessite de consulter le dossier autorisé par l'hôte.
                Lecture seule, chemins relatifs ; fichiers sensibles, liens et sorties de périmètre refusés.
                Aucun parcours automatique pour une salutation ou question générale.
                Appels, lecture, recherche et taille des résultats bornés par le runtime.
                Les erreurs et troncatures doivent être signalées. Aucun accès réseau dans ce contexte.
                """)
        }
    }

    private static func entry(schema: ToolSpec, usage: String) -> Entry {
        let function = schema["function"] as? [String: any Sendable] ?? [:]
        return Entry(name: function["name"] as? String ?? "",
                     description: function["description"] as? String ?? "", usage: usage, schema: schema)
    }
}

actor NoctisToolDispatcher {
    private let registry: NoctisToolRegistry
    private let local: ConversationToolDispatcher?
    private let web: WebToolDispatcher
    private var remainingCalls = 8
    private var remainingOpens = 4
    private var pageURLs: Set<String>

    init(registry: NoctisToolRegistry, web: WebToolDispatcher, userPrompt: String = "") {
        pageURLs = Self.userURLs(userPrompt)
        self.registry = registry
        local = registry.workspace.map { ConversationToolDispatcher(registry: $0) }
        self.web = web
    }

    func execute(_ call: ToolCall) async throws -> String {
        try Task.checkCancellation()
        guard remainingCalls > 0 else { throw AgentError.iterationLimit }
        remainingCalls -= 1
        guard registry.permits(call.function.name) else { throw WebToolError.unsupportedTool("unsupported") }
        if let local { return try await local.execute(call) }
        if call.function.name == WebOpenTool.name {
            let url = try WebOpenTool.validate(call)
            guard pageURLs.contains(url.absoluteString) else { throw WebToolError.pageNotAuthorized }
            guard remainingOpens > 0 else { throw WebPageError.requestLimit }
            remainingOpens -= 1
        }
        let output = try await web.execute(call)
        if call.function.name == WebSearchTool.name,
           let envelope = try? JSONDecoder().decode(SearchPageURLs.self, from: Data(output.utf8)) {
            for result in envelope.results.prefix(5) {
                if let url = try? PublicWebURLPolicy.validate(result.url) { pageURLs.insert(url.absoluteString) }
            }
        }
        return output
    }

    private struct SearchPageURL: Decodable { let url: String }
    private struct SearchPageURLs: Decodable { let results: [SearchPageURL] }

    private static func userURLs(_ prompt: String) -> Set<String> {
        guard prompt.utf8.count <= 65_536,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return Set(detector.matches(in: prompt, range: range).prefix(32).compactMap { match in
            guard let raw = match.url?.absoluteString,
                  let url = try? PublicWebURLPolicy.validate(raw) else { return nil }
            return url.absoluteString
        })
    }
}
