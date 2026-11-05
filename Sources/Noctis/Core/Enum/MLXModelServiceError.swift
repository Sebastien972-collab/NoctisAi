import Foundation

public enum MLXModelServiceError: LocalizedError, Equatable {
    case modelNotLoaded
    case modelLoading
    case generationInProgress

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return String(localized: "error.model.not_loaded", defaultValue: "Le modèle Noctis n'est pas encore chargé.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .modelLoading:
            return String(localized: "error.model.loading", defaultValue: "Le chargement du modèle Noctis est déjà en cours.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .generationInProgress:
            return String(localized: "error.model.generation_in_progress", defaultValue: "Une génération Noctis est déjà en cours.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        }
    }
}
