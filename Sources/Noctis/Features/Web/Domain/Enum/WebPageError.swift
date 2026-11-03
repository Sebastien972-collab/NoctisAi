import Foundation

enum WebPageError: Error, LocalizedError, Equatable {
    case invalidURL, invalidResponse, unsupportedContentType, invalidEncoding
    case publicAccessDisabled, responseTooLarge, redirectDenied, unsupportedCompression
    case timedOut, transportFailure, noContent, invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidURL: "URL invalide ou destination non autorisée."
        case .invalidResponse: "Le serveur a retourné une réponse invalide."
        case .unsupportedContentType: "Type de contenu non autorisé."
        case .invalidEncoding: "Encodage de la page non pris en charge."
        case .publicAccessDisabled: "Ouverture Web désactivée : transport public sécurisé indisponible."
        case .responseTooLarge: "La réponse dépasse la limite autorisée."
        case .redirectDenied: "Redirection refusée."
        case .unsupportedCompression: "Réponse compressée non autorisée."
        case .timedOut: "Le délai de la requête Web est dépassé."
        case .transportFailure: "La requête Web a échoué."
        case .noContent: "Aucun contenu principal exploitable."
        case .invalidConfiguration: "Configuration réseau invalide."
        }
    }
}
