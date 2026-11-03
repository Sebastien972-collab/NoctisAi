import Foundation

public enum MLXModelServiceError: LocalizedError, Equatable {
    case modelNotLoaded
    case modelLoading
    case generationInProgress

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Le modèle Noctis n'est pas encore chargé."
        case .modelLoading:
            return "Le chargement du modèle Noctis est déjà en cours."
        case .generationInProgress:
            return "Une génération Noctis est déjà en cours."
        }
    }
}
