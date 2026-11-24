// Created by Sébastien DAGUIN
import Foundation

/// Archives full host history even when AgentLoop shortens its model context.
struct IOSConversationTranscript: Sendable {
    private var messages: [ChatMessage]
    private var transcript: RunTranscript

    init(history: [ChatMessage], prompt: String) {
        messages = history + [.user(prompt)]
        transcript = RunTranscript(initial: messages)
    }

    var completed: Bool { transcript.completed }

    mutating func observe(_ event: StreamEvent) {
        switch event.kind {
        case let .iterationCompleted(usage, iteration, history):
            guard case .assistant = history.last else { return }
            if let assistant = history.last { messages.append(assistant) }
            transcript.observe(StreamEvent(kind: .iterationCompleted(
                usage: usage, iteration: iteration, history: messages
            )))
        case let .toolCallCompleted(id, name, result):
            messages.append(.tool(id: id, name: name, content: result.content))
            transcript.observe(event)
        case let .finished(usage, content, reason, _):
            let history = (try? messages.sanitizedTerminalHistory(finalContent: content)) ?? messages
            transcript.observe(StreamEvent(kind: .finished(
                tokenUsage: usage, content: content, reason: reason, history: history
            )))
        default:
            transcript.observe(event)
        }
    }

    func settled(error: (any Error)?) -> [ChatMessage] {
        transcript.final ?? transcript.interrupted(error: error)
    }
}
