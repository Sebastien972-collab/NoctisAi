//
//  HTTPWebPageServiceTests.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Foundation
import Testing
@testable import Noctis

struct HTTPWebPageServiceTests {

    @Test
    func rejectsUnsupportedScheme() async {
        let service = HTTPWebPageService()

        do {
            _ = try await service.open(
                url: URL(string: "file:///etc/passwd")!
            )

            Issue.record("Une erreur était attendue.")
        } catch WebPageError.invalidURL {
            // Comportement attendu.
        } catch {
            Issue.record("Erreur inattendue : \(error)")
        }
    }
}