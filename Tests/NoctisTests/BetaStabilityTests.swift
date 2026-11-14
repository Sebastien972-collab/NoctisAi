// Created by Sébastien DAGUIN

import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import Noctis

private struct BudgetFixtureProcessor: UserInputProcessor {
    let tokens: Int
    func prepare(input: UserInput) async throws -> LMInput {
        LMInput(tokens: MLXArray(Array(repeating: Int32(0), count: tokens)))
    }
}

@Suite("Beta input and generation boundaries")
struct BetaStabilityTests {
    @Test func countsTheRenderedInputIncludingToolSchemas() async throws {
        let accepted = BoundedModelProcessor(base: BudgetFixtureProcessor(tokens: 6_144))
        _ = try await accepted.prepare(input: UserInput(prompt: "Bonjour"))
        let refused = BoundedModelProcessor(base: BudgetFixtureProcessor(tokens: 6_145))
        await #expect(throws: MLXModelServiceError.contextLimit) {
            _ = try await refused.prepare(input: UserInput(prompt: "Bonjour"))
        }
        let tools: [ToolSpec] = [["description": String(repeating: "x", count: 262_144)]]
        await #expect(throws: MLXModelServiceError.contextLimit) {
            _ = try await accepted.prepare(input: UserInput(prompt: "Bonjour", tools: tools))
        }
    }

    @Test func modelWindowCanLowerButCannotRaiseTheBetaBudget() async throws {
        let small = BoundedModelProcessor(base: BudgetFixtureProcessor(tokens: 65), maximumInputTokens: 64)
        await #expect(throws: MLXModelServiceError.contextLimit) {
            _ = try await small.prepare(input: UserInput(prompt: "Bonjour"))
        }
        #expect(BoundedModelProcessor(base: BudgetFixtureProcessor(tokens: 0),
                                      maximumInputTokens: 100_000).maximumInputTokens == 6_144)
    }

    @Test func sharedLeaseExcludesAllOtherGenerationsAndInvalidatesSnapshots() throws {
        let access = ModelGenerationAccess()
        let oldRevision = access.revision
        let lease = try access.acquire(revision: oldRevision)
        #expect(throws: MLXModelServiceError.generationInProgress) { try access.acquire() }
        access.release(UUID())
        #expect(throws: MLXModelServiceError.generationInProgress) { try access.acquire() }
        access.invalidate()
        #expect(throws: MLXModelServiceError.sessionInvalidated) { try access.validate(lease, revision: oldRevision) }
        access.release(lease)
        #expect(throws: MLXModelServiceError.sessionInvalidated) { try access.acquire(revision: oldRevision) }
        let next = try access.acquire(revision: access.revision)
        access.release(next)
    }
}
