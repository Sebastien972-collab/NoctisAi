// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon
import os

/// Reuses Harmony's private KV state only for the tool result it actually generated.
final class GPTOSSToolContinuation: Sendable {
    struct Request: Sendable {
        let id = UUID()
        let messages: [Data]
        let tools: Data
        let instructions: String
    }

    private struct Pending: Sendable {
        let messages: [Data]
        let tools: Data
        let instructions: String
        let callID: String
        let toolName: String

        func matches(_ request: Request, result: Message) -> Bool {
            request.messages.dropLast().elementsEqual(messages)
                && request.tools == tools && request.instructions == instructions
                && result["role"] as? String == "tool"
                && result["tool_call_id"] as? String == callID
                && result["name"] as? String == toolName
        }
    }

    private struct State {
        var requestID: UUID?
        var pending: Pending?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin(messages: [MLXLMCommon.Chat.Message], tools: [ToolSpec], instructions: String)
    -> (request: Request, canReuseSession: Bool)? {
        guard !messages.isEmpty,
              messages.allSatisfy({ $0.images.isEmpty && $0.videos.isEmpty && $0.audios.isEmpty }) else {
            invalidate()
            return nil
        }
        let rendered = DefaultMessageGenerator().generate(messages: messages)
        guard let signatures = try? rendered.map(Self.signature), let toolSignature = try? Self.signature(tools),
              let result = rendered.last else {
            invalidate()
            return nil
        }
        let request = Request(messages: signatures, tools: toolSignature, instructions: instructions)
        return state.withLock {
            let canReuse = $0.pending?.matches(request, result: result) == true
            $0 = State(requestID: request.id)
            return (request, canReuse)
        }
    }

    func invalidate() {
        state.withLock { $0 = State() }
    }

    func observe(_ upstream: AsyncThrowingStream<Generation, Error>, request: Request)
    -> AsyncThrowingStream<Generation, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                var content = ""
                var calls: [MLXLMCommon.ToolCall] = []
                var stoppedNormally = false
                var rejected = false
                do {
                    for try await event in upstream {
                        try Task.checkCancellation()
                        switch event {
                        case .chunk(let text): content += text
                        case .toolCall(let call): calls.append(call)
                        case .info(let info): stoppedNormally = info.stopReason == .stop
                        case .rejectedToolCall: rejected = true
                        case .reasoning, .steering: break
                        }
                        if case .terminated = output.yield(event) { throw CancellationError() }
                    }
                    try Task.checkCancellation()
                    if stoppedNormally && !rejected {
                        record(request: request, content: content, calls: calls)
                    }
                    output.finish()
                } catch {
                    invalidate(requestID: request.id)
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { termination in
                if case .cancelled = termination {
                    self.invalidate(requestID: request.id)
                    task.cancel()
                }
            }
        }
    }

    private func record(request: Request, content: String, calls: [MLXLMCommon.ToolCall]) {
        guard calls.count == 1, let call = calls.first, let id = call.id,
              let signature = try? Self.signature(DefaultMessageGenerator().generate(
                message: .assistant(content, toolCalls: calls))) else { return }
        let pending = Pending(messages: request.messages + [signature], tools: request.tools,
                              instructions: request.instructions, callID: id, toolName: call.function.name)
        state.withLock {
            guard $0.requestID == request.id else { return }
            $0.pending = pending
        }
    }

    private func invalidate(requestID: UUID) {
        state.withLock { if $0.requestID == requestID { $0 = State() } }
    }

    private static func signature(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
