//
//  WebSearchTool.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import MLXLMCommon

enum WebSearchTool {

    static let name = "web_search"

    static let schema: ToolSpec = [
        "type": "function",
        "function": [
            "name": name,
            "description": """
                Recherche des informations sur Internet.
                Utilise cet outil pour obtenir des informations
                récentes, vérifier des faits et trouver des sources.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "La requête de recherche Web."
                    ]
                ],
                "required": ["query"],
                "additionalProperties": false
            ] as [String: any Sendable]
        ] as [String: any Sendable]
    ]
}