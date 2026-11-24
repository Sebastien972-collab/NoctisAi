// Created by Sébastien DAGUIN
#if os(iOS) && canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, *)
enum FoundationModelsSession {
    static func make(for request: FoundationModelsBridge.PreparedRequest) throws
        -> (session: LanguageModelSession, prompt: String) {
        let context = try Self.context(for: request)
        // Only AgentLoop may execute tools; no Apple Tool callbacks are registered.
        let session = LanguageModelSession(
            model: SystemLanguageModel.default, tools: [], transcript: context.transcript
        )
        return (session, context.prompt)
    }

    static func context(for request: FoundationModelsBridge.PreparedRequest) throws
        -> (transcript: Transcript, prompt: String) {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                id: UUID().uuidString, segments: [text(request.instructions)], toolDefinitions: []
            ))
        ]
        var pending: [String] = []
        for message in request.history {
            switch message {
            case .user, .userMultimodal:
                pending.append(try FoundationModelsBridge.userText(message))
            case let .assistant(assistant):
                if !pending.isEmpty {
                    entries.append(.prompt(Transcript.Prompt(id: UUID().uuidString, segments: pending.map(text))))
                    pending.removeAll()
                }
                let segments = try FoundationModelsBridge.assistantHistorySegments(assistant).map(text)
                entries.append(.response(Transcript.Response(id: UUID().uuidString, assetIDs: [], segments: segments)))
            case let .tool(id, name, content):
                // Native tool-history entries can require live Tool bindings when rehydrating on iOS 26.
                pending.append(try FoundationModelsBridge.toolResultHistoryText(id: id, name: name, content: content))
            case .system:
                throw AgentError.invalidArguments
            }
        }
        // Merge trailing results into the new prompt instead of appending consecutive native prompts.
        return (Transcript(entries: entries), (pending + [request.prompt]).joined(separator: "\n\n"))
    }

    private static func text(_ content: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(id: UUID().uuidString, content: content))
    }
}
#endif
