//
//  SearXNGServiceTests.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


import Foundation
import Testing
@testable import Noctis

struct SearXNGServiceTests {

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_SEARXNG_TESTS"] == "1"
        )
    )
    func searchReturnsResults() async throws {
        let service = SearXNGService()

        let results = try await service.search(
            query: "Swift programming language"
        )

        #expect(!results.isEmpty)
        #expect(results.allSatisfy { !$0.title.isEmpty })
    }
}
