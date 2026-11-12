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

    init(workspace: ToolRegistry? = nil) {
        self.workspace = workspace
        hasWorkspace = workspace != nil
        if let workspace {
            entries = Self.workspaceEntries(workspace.schemas)
        } else {
            entries = [Self.entry(schema: WebSearchTool.schema, usage: """
                Pour une information récente, vérifier un fait ou trouver une source.
                Permission réseau de la session ; SearXNG configuré, disponibilité non garantie.
                Une requête de 300 caractères/1200 octets au maximum, 5 résultats au maximum.
                Les extraits ne constituent pas une lecture intégrale de page. Ne pas envoyer de contenu local.
                """)]
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

    init(registry: NoctisToolRegistry, web: WebToolDispatcher) {
        self.registry = registry
        local = registry.workspace.map { ConversationToolDispatcher(registry: $0) }
        self.web = web
    }

    func execute(_ call: MLXLMCommon.ToolCall) async throws -> String {
        try Task.checkCancellation()
        guard remainingCalls > 0 else { throw AgentError.iterationLimit }
        remainingCalls -= 1
        guard registry.permits(call.function.name) else { throw WebToolError.unsupportedTool("unsupported") }
        if let local {
            let output = try await local.execute(call)
            if let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String],
               object.count == 1, let code = object["error"], let error = NoctisAgent.AgentError(rawValue: code) {
                throw error
            }
            return output
        }
        return try await web.execute(call)
    }
}
