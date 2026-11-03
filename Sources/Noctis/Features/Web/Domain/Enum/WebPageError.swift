//
//  WebPageError.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

enum WebPageError: LocalizedError {
    
    case invalidURL
    case invalidResponse
    case unsupportedContentType
    case invalidEncoding
    var errorDescription: String? {
        
        switch self {
        case .invalidURL:
            "URL invalide ou protocole non autorisé."
        case .invalidResponse:
            "Le serveur a retourné une réponse invalide."
        case .unsupportedContentType:
            "Le contenu de cette URL n'est pas une page HTML."
        case .invalidEncoding:
            "Impossible de décoder le contenu de la page."
        }
    }
    
}
