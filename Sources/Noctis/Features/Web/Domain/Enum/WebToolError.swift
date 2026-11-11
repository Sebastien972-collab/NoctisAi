//
//  WebToolError.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation

enum WebToolError: LocalizedError {
    
    case unsupportedTool(String)
    case invalidArguments
    case pageNotAuthorized

    var errorDescription: String? {
        switch self {
        case .unsupportedTool:
            return String(localized: "error.web_tool.unsupported", defaultValue: "Outil Web non pris en charge.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .pageNotAuthorized:
            return "Cette page doit être fournie par l'utilisateur ou issue d'une recherche de ce tour."
        case .invalidArguments:
            return String(localized: "error.web_tool.invalid_arguments", defaultValue: "Arguments invalides pour l'outil Web.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        }
        
    }
}
