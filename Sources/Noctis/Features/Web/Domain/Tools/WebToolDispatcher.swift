//
//  WebToolDispatcher.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import MLXLMCommon

struct WebToolDispatcher: Sendable {

    private let searchService: any WebSearchService

    init(searchService: any WebSearchService) {
        self.searchService = searchService
    }

    func execute(_ call: ToolCall) async throws -> String {
        print("🔧 [Noctis Tool] \(call.function.name)")
        
        switch call.function.name {

        case WebSearchTool.name:
            guard
                case .string(let rawQuery) =
                    call.function.arguments["query"]
            else {
                throw WebToolError.invalidArguments
            }

            let query = rawQuery.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            guard !query.isEmpty, query.count <= 300 else {
                throw WebToolError.invalidArguments
            }
            print("🔎 [SearXNG] Recherche : \(query)")
            let results = try await searchService.search(
                query: query
            )

            guard !results.isEmpty else {
                return "Aucun résultat trouvé pour : \(query)"
            }

            return results.prefix(5).enumerated().map {
                index, result in

                """
                Résultat \(index + 1)
                Titre : \(result.title)
                URL : \(result.url.absoluteString)
                Description : \(result.content ?? "Non disponible")
                """
            }
            .joined(separator: "\n\n")

        default:
            throw WebToolError.unsupportedTool(
                call.function.name
            )
        }
    }
}
