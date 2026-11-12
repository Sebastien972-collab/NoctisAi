//
// NoctisRuntimeContext.swift
// Noctis
//
// Created by Sébastien DAGUIN.
//

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
        formatter.formatOptions = [
            .withFullDate,
            .withDashSeparatorInDate
        ]

        let toolNames = registry.entries.map(\.name)

        let permissions: String

        if registry.hasWorkspace {
            permissions = """
                Un dossier local a été autorisé
                en lecture seule par l'application hôte.
                """
        } else {
            permissions = """
                Aucun dossier local n'est actuellement autorisé.
                """
        }

        let webAvailable = toolNames.contains("web_search")
        let webOpenAvailable = toolNames.contains("web_open")

        let webStatus = webAvailable
            ? "Recherche Web disponible via le service configuré."
            : "Recherche Web indisponible dans cette session."

        let webOpenStatus = webOpenAvailable
            ? "Consultation des pages Web autorisée."
            : "Consultation directe des pages Web indisponible."

        let availableTools = toolNames.isEmpty
            ? "Aucun"
            : toolNames.joined(separator: ", ")

        return """
            CONTEXTE DE SESSION

            Date actuelle : \(formatter.string(from: date))
            Fuseau horaire : \(timeZone.identifier)
            Plateforme : \(platform)

            Utilise cette date pour interpréter correctement
            aujourd'hui, hier, demain et récemment.

            PERMISSIONS EFFECTIVES

            \(permissions)
            \(webStatus)
            \(webOpenStatus)

            Outils disponibles : \(availableTools)

            Les outils et permissions réels sont déterminés
            exclusivement par l'application hôte.
            """
    }
}
