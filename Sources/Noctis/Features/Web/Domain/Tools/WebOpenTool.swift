//
//  WebOpenTool.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 05/11/2026.
//

import MLXLMCommon

enum WebOpenTool {
    static let name = "web_open"

    static let schema: ToolSpec = [
        "type": "function",
        "function": [
            "name": name,
            "description": """
                Consulte et extrait le contenu textuel d'une page Web à partir de son URL.
                Utilise cet outil lorsque tu disposes d'une URL spécifique (fournie par l'utilisateur ou issue d'une recherche) pour en lire le contenu complet et en faire le résumé.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "L'URL complète de la page Web à consulter (ex: https://example.com/article)."
                    ]
                ],
                "required": ["url"],
                "additionalProperties": false
            ] as [String: any Sendable]
        ] as [String: any Sendable]
    ]
}
