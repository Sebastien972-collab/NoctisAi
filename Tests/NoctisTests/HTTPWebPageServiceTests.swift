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

    @Test
    func opensArticleSuccessfully() async throws {
        let service = HTTPWebPageService(protocolClasses: [WebFixtureProtocol.self])
        let page = try await service.open(url: #require(URL(string: "https://www.swift.org/article")))
        #expect(page.title == "Swift")
        #expect(page.content.contains("Swift is a general-purpose"))
        #expect(page.url == "https://www.swift.org/article")
        #expect(page.isTruncated == false)
    }
}
