// Created by Sébastien DAGUIN
import Foundation

public enum IOSModelPreference: String, CaseIterable, Codable, Sendable {
    case automatic
    case foundationModels
    case mlx
}

public enum IOSModelProvider: String, Codable, Sendable {
    case foundationModels
    case mlx
}

public enum IOSFoundationModelsAvailability: Equatable, Sendable {
    case available
    case requiresIOS26
    case frameworkUnavailable
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unknown

    public var reason: String? {
        switch self {
        case .available: nil
        case .requiresIOS26: "Le modèle Apple local nécessite iOS 26 ou une version ultérieure."
        case .frameworkUnavailable: "Foundation Models n’est pas disponible dans cette version de l’application."
        case .appleIntelligenceNotEnabled: "Apple Intelligence n’est pas activé sur cet appareil."
        case .deviceNotEligible: "Cet appareil ne prend pas en charge le modèle Apple local."
        case .modelNotReady: "Le modèle Apple local n’est pas encore prêt sur cet appareil."
        case .unknown: "Le modèle Apple local est actuellement indisponible."
        }
    }
}

public struct IOSModelSelection: Equatable, Sendable {
    public let preference: IOSModelPreference
    public let provider: IOSModelProvider
    public let foundationModelsAvailability: IOSFoundationModelsAvailability

    public var fallbackReason: String? {
        guard preference == .automatic, provider == .mlx else { return nil }
        return foundationModelsAvailability.reason
    }
}

public enum IOSModelServiceError: LocalizedError, Equatable, Sendable {
    case foundationModelsUnavailable(IOSFoundationModelsAvailability)
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .foundationModelsUnavailable(let availability):
            availability.reason ?? "Le modèle Apple local est indisponible."
        case .incompleteResponse:
            "La réponse s’est arrêtée avant la confirmation de sa fin."
        }
    }
}

/// Pure selection policy; only IOSModelService performs runtime availability checks and loading.
public enum IOSModelConfiguration {
    public static let mlxModelID = "mlx-community/Ministral-3-3B-Instruct-2512-4bit"

    public static func select(
        preference: IOSModelPreference,
        availability: IOSFoundationModelsAvailability
    ) throws -> IOSModelSelection {
        let provider: IOSModelProvider
        switch preference {
        case .automatic:
            provider = availability == .available ? .foundationModels : .mlx
        case .mlx:
            provider = .mlx
        case .foundationModels:
            guard availability == .available else {
                throw IOSModelServiceError.foundationModelsUnavailable(availability)
            }
            provider = .foundationModels
        }
        return IOSModelSelection(
            preference: preference, provider: provider, foundationModelsAvailability: availability
        )
    }
}
