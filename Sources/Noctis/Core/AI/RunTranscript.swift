/// Collects a single turn in event order, including tool results published before cancellation.
struct RunTranscript {
    let initial: [ChatMessage]
    private var pending: [ChatMessage]?
    private var partialAnswer = ""
    private(set) var completed = false
    private(set) var final: [ChatMessage]?

    init(initial: [ChatMessage]) { self.initial = initial }

    mutating func observe(_ event: StreamEvent) {
        switch event.kind {
        case .delta(let text):
            partialAnswer.append(text)
        case .iterationCompleted(_, _, let messages):
            pending = messages
            partialAnswer = ""
        case .toolCallCompleted(let id, let name, let result):
            pending?.append(.tool(id: id, name: name, content: result.content))
        case .finished(_, _, let reason, let messages):
            completed = reason == .completed
            final = messages
        default: break
        }
    }

    func interrupted(error: (any Error)?) -> [ChatMessage] {
        let noResults = error as? MLXModelServiceError == .noSearchResults
        var messages = pending ?? initial
        if pending != nil, let index = messages.lastIndex(where: { if case .assistant = $0 { true } else { false } }),
           case .assistant(let assistant) = messages[index], !assistant.toolCalls.isEmpty {
            let results = messages.suffix(from: index + 1).compactMap { message -> (String, ChatMessage)? in
                guard case .tool(let id, _, _) = message else { return nil }
                return (id, message)
            }
            messages.removeSubrange((index + 1)...)
            messages += assistant.toolCalls.map { call in
                results.first { $0.0 == call.id }?.1 ?? .tool(id: call.id, name: call.name,
                    content: noResults && call.name == "web_search" ? "Recherche terminée sans source."
                        : "Action interrompue ; aucun résultat confirmé.")
            }
        }
        if (try? messages.validateForAgentHistory()) == nil { messages = initial }
        if case .assistant(let last) = messages.last, last.toolCalls.isEmpty { return messages }
        let notice = noResults ? MLXModelServiceError.noSearchResults.localizedDescription
            : "Réponse interrompue avant la fin."
        let content = partialAnswer.isEmpty ? notice : partialAnswer + "\n\n" + notice
        messages.append(.assistant(AssistantMessage(content: content)))
        return messages
    }
}
