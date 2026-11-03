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

    var errorDescription: String? {
        switch self {
        case .unsupportedTool:
            return "Outil Web non pris en charge."
        case .invalidArguments:
            return "Arguments invalides pour l'outil Web."
        }
        
    }
}
