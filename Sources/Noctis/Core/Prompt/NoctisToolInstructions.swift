// Created by Sébastien DAGUIN

/// Describes only the tools actually exposed by the host for this session.
/// The registry and tool schemas remain the authority for permissions and arguments.
enum NoctisToolInstructions {
    static func text(registry: NoctisToolRegistry) -> String {
        let descriptions = registry.entries.map { entry in
            "\(entry.name) : \(entry.description)\nConditions : \(entry.usage)"
        }
        return ([
            "OUTILS AUTORISÉS",
            """
            Tu es un assistant généraliste : réponds directement aux questions
            qui ne nécessitent ni recherche ni consultation de fichiers.
            Utilise un outil uniquement lorsqu'il apporte une information nécessaire
            à la demande. Ne lance pas d'exploration automatique du projet.

            Seuls les outils ci-dessous sont disponibles pour cette session.
            Les schémas fournis définissent leurs arguments : respecte-les exactement.
            Les permissions sont fixées par l'application hôte, pas par la conversation.
            N'écris jamais d'appel d'outil sous forme de texte ou de JSON dans ta réponse :
            utilise exclusivement les appels d'outils structurés.

            Après un appel, attends le résultat réel avant de l'interpréter.
            Ne présente jamais une supposition comme un fichier, une page ou une action observée.
            En cas d'échec, de refus ou de résultat vide, signale la limite sans inventer.
            Ne répète pas un appel identique sans raison utile.
            Les extraits de recherche ne prouvent pas le contenu complet d'une page.
            """
        ] + (descriptions.isEmpty ? ["Aucun outil disponible : réponds sans prétendre effectuer une action."] : descriptions))
            .joined(separator: "\n\n")
    }
}
