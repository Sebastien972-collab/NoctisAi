// Created by Sébastien DAGUIN

import Foundation
import Testing
@testable import Noctis

@Suite("Cancellation before the first model event", .timeLimit(.minutes(1)))
struct GenerationCancellationTests {
    @Test func silentStructuredGenerationCanBeCancelledAndFollowedByAnotherTurn() async throws {
        let fixture = try await ReliabilityFixture([
            [.pause], [.text("After cancellation")]
        ], workspaceEnabled: false, profile: .gptOSS)
        defer { fixture.cleanup() }
        let consumer = Task {
            _ = try await fixture.run("First")
            try Task.checkCancellation()
        }
        defer { consumer.cancel() }
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while fixture.probe.state.withLock({ $0.active }) == 0 && ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(fixture.probe.state.withLock { $0.active } == 1)

        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        await #expect(throws: CancellationError.self) { _ = try await consumer.value }
        _ = await fixture.agent.settledHistory()
        // The fixture's silent producer would otherwise sleep for thirty seconds.
        #expect(cancelledAt.duration(to: .now) < .seconds(5))
        #expect(fixture.probe.state.withLock { $0.active } == 0)

        let events = try await fixture.run("Next")
        let text = events.compactMap { event -> String? in
            if case .delta(let text) = event.kind { text } else { nil }
        }.joined()
        #expect(text == "After cancellation")
        #expect(fixture.probe.state.withLock { $0.maxActive } == 1)
    }
}
