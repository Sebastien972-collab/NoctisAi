// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon

/// Reserved contract only. Never registered until an operational transport has been verified.
enum WebOpenTool {
    static let name = "web_open"

    static let schema: ToolSpec = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Consulter le texte principal d'une page HTTPS publique, sans ressources secondaires.",
            "parameters": [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "URL HTTPS publique sur le port 443."]],
                "required": ["url"],
                "additionalProperties": false
            ] as [String: any Sendable]
        ] as [String: any Sendable]
    ]

    static func validate(_ call: ToolCall) throws -> URL {
        guard call.function.name == name, call.function.arguments.count == 1,
              case .string(let raw) = call.function.arguments["url"] else {
            throw WebToolError.invalidArguments
        }
        return try PublicWebURLPolicy.validate(raw)
    }
}
