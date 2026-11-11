// Created by Sébastien DAGUIN

enum NoctisToolInstructions {
    static func text(registry: NoctisToolRegistry) -> String {
        let descriptions = registry.entries.map { entry in
            "\(entry.name) : \(entry.description)\nUsage, limites et permissions : \(entry.usage)"
        }
        return (["OUTILS AUTORISÉS", "Seuls les noms ci-dessous correspondent aux schémas fournis."]
            + (descriptions.isEmpty ? ["Aucun outil disponible."] : descriptions))
            .joined(separator: "\n\n")
    }
}
