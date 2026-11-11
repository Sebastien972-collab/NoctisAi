import Foundation

enum WebPageError: Error, LocalizedError, Equatable {
    case invalidURL, invalidResponse, unsupportedContentType, invalidEncoding
    case publicAccessDisabled, responseTooLarge, redirectDenied, unsupportedCompression
    case timedOut, transportFailure, noContent, invalidConfiguration, requestLimit, tlsFailure

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "error.network.invalid_url", defaultValue: "URL invalide ou destination non autorisée.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .invalidResponse: String(localized: "error.network.invalid_response", defaultValue: "Le serveur a retourné une réponse invalide.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .unsupportedContentType: String(localized: "error.network.unsupported_content_type", defaultValue: "Type de contenu non autorisé.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .invalidEncoding: String(localized: "error.network.invalid_encoding", defaultValue: "Encodage de la page non pris en charge.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .publicAccessDisabled: String(localized: "error.network.public_access_disabled", defaultValue: "Ouverture Web désactivée : transport public sécurisé indisponible.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .responseTooLarge: String(localized: "error.network.response_too_large", defaultValue: "La réponse dépasse la limite autorisée.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .redirectDenied: String(localized: "error.network.redirect_denied", defaultValue: "Redirection refusée.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .unsupportedCompression: String(localized: "error.network.unsupported_compression", defaultValue: "Réponse compressée non autorisée.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .requestLimit: "Limite de consultations Web atteinte. Réessayez dans un instant."
        case .tlsFailure: "Le certificat du site ne permet pas une connexion sécurisée."
        case .timedOut: String(localized: "error.network.timeout", defaultValue: "Le délai de la requête Web est dépassé.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .transportFailure: String(localized: "error.network.transport_failure", defaultValue: "La requête Web a échoué.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .noContent: String(localized: "error.web_page.no_content", defaultValue: "Aucun contenu principal exploitable.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .invalidConfiguration: String(localized: "error.network.invalid_configuration", defaultValue: "Configuration réseau invalide.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        }
    }
}
