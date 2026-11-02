//
//  MLXModelServiceError.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

enum MLXModelServiceError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Le modèle Noctis n'est pas encore chargé."
        }
    }
}
