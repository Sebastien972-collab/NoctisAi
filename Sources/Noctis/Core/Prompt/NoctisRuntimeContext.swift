// Created by Sébastien DAGUIN

import Foundation

struct NoctisRuntimeContext: Sendable {
    var date = Date.now
    var timeZone = TimeZone.current
    var platform: String = {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #else
        "Autre plateforme"
        #endif
    }()

    func text(registry: NoctisToolRegistry) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        let permissions = registry.hasWorkspace
            ? "Dossier autorisé en lecture seule. Réseau désactivé pour protéger les données locales."
            : "Aucun accès aux fichiers locaux. Recherche réseau via le service SearXNG configuré."
        return """
            CONTEXTE DE SESSION
            Date actuelle : \(formatter.string(from: date)) (\(timeZone.identifier)).
            Utilise cette date pour interpréter aujourd'hui, hier, demain et récemment.
            Plateforme : \(platform). Modèle exécuté localement.
            Permissions effectives : \(permissions)
            Outils activés : \(registry.entries.map(\.name).joined(separator: ", ")).
            Restriction : consultation des pages désactivée, transport public non validé.
            Aucun outil d'écriture, de commande système ou d'accès aux applications personnelles.
            """
    }
}
