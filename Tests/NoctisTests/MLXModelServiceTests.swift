//
//  MLXModelServiceTests.swift
//  NoctisTests
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import Testing
@testable import Noctis

@Suite("Garde du moteur MLX sans chargement du modèle")
struct MLXModelServiceTests {
    @Test("Refuse la génération tant que le modèle n’est pas chargé",
          arguments: ["Bonjour", "", " \t\n "])
    func generateBeforeLoadingThrows(prompt: String) async throws {
        let service = MLXModelService()

        let error = await #expect(throws: MLXModelServiceError.self) {
            _ = try await service.generate(prompt: prompt)
        }

        let failure = try #require(error)
        #expect(failure.localizedDescription == "Le modèle Noctis n'est pas encore chargé.")
    }
}
