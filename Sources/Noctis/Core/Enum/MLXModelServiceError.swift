// Created by Sébastien DAGUIN
import Foundation

public enum MLXModelServiceError: LocalizedError, Equatable {
    case modelNotLoaded
    case modelLoading
    case noSearchResults
    case contextLimit
    case sessionInvalidated
    case responseLimit
    case toolLimit
    case generationInProgress

    public var errorDescription: String? {
        switch self {
        case .noSearchResults:
            return String(localized: "error.web.no_search_results", defaultValue:
                "Aucune source n’a été trouvée pour cette recherche. Tu peux essayer une nouvelle demande.",
                bundle: .module)
        case .contextLimit:
            return String(localized: "error.model.context_limit", defaultValue:
            "Contexte trop volumineux. Commence une nouvelle conversation ; l’historique reste conservé.",
                          bundle: .module)
        case .sessionInvalidated:
            return String(localized: "error.model.session_invalidated", defaultValue:
                            "Les permissions ont changé. Crée une nouvelle session pour continuer.", bundle: .module)
        case .responseLimit:
            return String(localized: "error.model.response_limit", defaultValue:
                            "La réponse a atteint la limite de génération et reste incomplète.", bundle: .module)
        case .toolLimit:
            return String(localized: "error.model.tool_limit", defaultValue:
                            "La limite d’outils a été atteinte. La tâche reste incomplète.", bundle: .module)
        case .modelNotLoaded:
            return String(localized: "error.model.not_loaded", defaultValue: "Le modèle Noctis n'est pas encore chargé.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .modelLoading:
            return String(localized: "error.model.loading", defaultValue: "Le chargement du modèle Noctis est déjà en cours.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .generationInProgress:
            return String(localized: "error.model.generation_in_progress", defaultValue: "Une génération Noctis est déjà en cours.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        }
    }
}
