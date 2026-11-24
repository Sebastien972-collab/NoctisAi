// Created by Sébastien DAGUIN
import Foundation
import os

/// A run keeps its lease until every Apple producer has completed cancellation cleanup.
final class FoundationModelsRunTasks: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [UUID: [Task<Void, Never>]]())

    func register(_ task: Task<Void, Never>, for lease: UUID) {
        state.withLock { $0[lease, default: []].append(task) }
    }

    func finish(_ lease: UUID) async {
        let producers = state.withLock { $0[lease] ?? [] }
        for producer in producers { producer.cancel() }
        for producer in producers { await producer.value }
        state.withLock { _ = $0.removeValue(forKey: lease) }
    }
}
