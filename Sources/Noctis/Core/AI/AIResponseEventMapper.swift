// Created by Sébastien DAGUIN
import Foundation

/// Waits for complete arguments before describing a tool invocation to the interface.
struct AIResponseEventMapper {
    private var startedTools: Set<String> = []

    mutating func events(for event: StreamEvent) -> [AIResponseEvent] {
        switch event.kind {
        case let .delta(text): return [.textDelta(text)]
        case let .reasoningDelta(text): return [.reasoningDelta(text)]
        case let .iterationCompleted(_, _, history):
            guard case let .assistant(message) = history.last else { return [] }
            return message.toolCalls.compactMap { call in
                guard call.name != "finish", startedTools.insert(call.id).inserted else { return nil }
                return .toolStarted(id: call.id, name: call.name, arguments: call.arguments)
            }
        case let .toolCallCompleted(id, name, result):
            guard name != "finish" else { return [] }
            return [.toolCompleted(id: id, name: name, result: result.content, isError: result.isError)]
        default: return []
        }
    }
}
