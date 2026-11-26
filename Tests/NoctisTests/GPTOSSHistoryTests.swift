// Created by Sébastien DAGUIN

import Foundation
import Testing
import MLXLMCommon
@testable import Noctis

@Suite("GPT-OSS tool continuation without model loading", .timeLimit(.minutes(1)))
struct GPTOSSHistoryTests {
    private let call = MLXLMCommon.ToolCall(
        function: .init(name: "web_search", arguments: ["query": MLXLMCommon.JSONValue.string("Swift")]),
        id: "call_0123456789abcdef0123456789abcdef")
    private let instructions = "Test"

    private var tools: [ToolSpec] { NoctisToolRegistry().schemas }
    private var prompt: [MLXLMCommon.Chat.Message] { [.user("Recherche Swift")] }
    private var resumed: [MLXLMCommon.Chat.Message] {
        prompt + [.assistant("Je vérifie.", toolCalls: [call]), .tool("SOURCE_1", id: call.id, name: "web_search")]
    }

    @Test func matchingToolResultReusesTheLiveSessionOnce() async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        #expect(!first.canReuseSession)
        try await finish(tracker, request: first.request)

        let next = try #require(tracker.begin(messages: resumed, tools: tools, instructions: instructions))
        #expect(next.canReuseSession)
        #expect(tracker.begin(messages: resumed, tools: tools, instructions: instructions)?.canReuseSession == false)
    }

    @Test func consecutiveToolsKeepTheCompletePublicTranscript() async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        try await finish(tracker, request: first.request)
        let next = try #require(tracker.begin(messages: resumed, tools: tools, instructions: instructions))
        #expect(next.canReuseSession)
        let secondCall = MLXLMCommon.ToolCall(function: call.function,
                                             id: "call_abcdef0123456789abcdef0123456789")
        let events: [Generation] = [.reasoning("PRIVATE_REASONING"), .toolCall(secondCall), completion(.stop)]
        try await drain(tracker.observe(stream(events), request: next.request))
        let final = resumed + [.assistant("", toolCalls: [secondCall]),
                               .tool("SOURCE_2", id: secondCall.id, name: "web_search")]
        #expect(tracker.begin(messages: final, tools: tools, instructions: instructions)?.canReuseSession == true)
    }

    @Test(arguments: ["history", "content", "arguments", "call_id", "result_id", "result_name",
                      "tools", "instructions"])
    func changedTranscriptOrRequestCannotReusePrivateState(_ change: String) async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        try await finish(tracker, request: first.request)
        var messages = resumed
        var nextTools = tools
        var nextInstructions = instructions
        switch change {
        case "history": messages[0] = .user("Un autre sujet")
        case "content": messages[1] = .assistant("Texte modifié", toolCalls: [call])
        case "arguments":
            let changed = MLXLMCommon.ToolCall(
                function: .init(name: "web_search", arguments: ["query": MLXLMCommon.JSONValue.string("Metal")]),
                id: call.id)
            messages[1] = .assistant("Je vérifie.", toolCalls: [changed])
        case "call_id":
            let changed = MLXLMCommon.ToolCall(function: call.function, id: "call_abcdef0123456789abcdef0123456789")
            messages[1] = .assistant("Je vérifie.", toolCalls: [changed])
        case "result_id":
            messages[2] = .tool("SOURCE_1", id: "call_abcdef0123456789abcdef0123456789", name: "web_search")
        case "result_name": messages[2] = .tool("SOURCE_1", id: call.id, name: "web_open")
        case "tools": nextTools = []
        default: nextInstructions = "Instructions modifiées"
        }
        #expect(tracker.begin(messages: messages, tools: nextTools,
                              instructions: nextInstructions)?.canReuseSession == false)
    }

    @Test(arguments: [GenerateStopReason.length, .cancelled, .interrupted, .steered])
    func incompleteGenerationCannotArmAContinuation(_ reason: GenerateStopReason) async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        try await finish(tracker, request: first.request, reason: reason)
        #expect(tracker.begin(messages: resumed, tools: tools, instructions: instructions)?.canReuseSession == false)
    }

    @Test func rejectedCallCannotArmAContinuation() async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        let events: [Generation] = [
            .chunk("Je vérifie."), .toolCall(call),
            .rejectedToolCall(.init(reason: .invalidArguments, format: .gptOSS, rawText: "INVALID")),
            completion(.stop)
        ]
        try await drain(tracker.observe(stream(events), request: first.request))
        #expect(tracker.begin(messages: resumed, tools: tools, instructions: instructions)?.canReuseSession == false)
    }

    @Test func failedGenerationCannotArmAContinuation() async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        let upstream = AsyncThrowingStream<Generation, Error> { output in
            output.yield(.chunk("Je vérifie."))
            output.yield(.toolCall(call))
            output.yield(completion(.stop))
            output.finish(throwing: MLXModelServiceError.contextLimit)
        }
        await #expect(throws: MLXModelServiceError.contextLimit) {
            try await drain(tracker.observe(upstream, request: first.request))
        }
        #expect(tracker.begin(messages: resumed, tools: tools, instructions: instructions)?.canReuseSession == false)
    }

    @Test func consumerCancellationCannotArmAContinuation() async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        let (upstream, input) = AsyncThrowingStream<Generation, Error>.makeStream()
        let (received, signal) = AsyncStream<Void>.makeStream()
        let observed = tracker.observe(upstream, request: first.request)
        let consumer = Task {
            for try await _ in observed { signal.yield(()) }
        }
        input.yield(.toolCall(call))
        var iterator = received.makeAsyncIterator()
        _ = await iterator.next()
        consumer.cancel()
        _ = await consumer.result
        input.finish()
        signal.finish()
        #expect(tracker.begin(messages: resumed, tools: tools, instructions: instructions)?.canReuseSession == false)
    }

    @Test(arguments: [true, false])
    func resetOrNewRequestPreventsLateCompletionFromRearming(_ reset: Bool) async throws {
        let tracker = GPTOSSToolContinuation()
        let first = try #require(tracker.begin(messages: prompt, tools: tools, instructions: instructions))
        if reset {
            tracker.invalidate()
        } else {
            _ = tracker.begin(messages: [.user("Nouvelle conversation")], tools: tools, instructions: instructions)
        }
        try await finish(tracker, request: first.request)
        #expect(tracker.begin(messages: resumed, tools: tools, instructions: instructions)?.canReuseSession == false)
    }

    private func finish(_ tracker: GPTOSSToolContinuation, request: GPTOSSToolContinuation.Request,
                        reason: GenerateStopReason = .stop) async throws {
        let events: [Generation] = [
            .reasoning("PRIVATE_REASONING"), .chunk("Je vérifie."), .toolCall(call), completion(reason)
        ]
        try await drain(tracker.observe(stream(events), request: request))
    }

    private func stream(_ events: [Generation]) -> AsyncThrowingStream<Generation, Error> {
        AsyncThrowingStream { output in
            for event in events { output.yield(event) }
            output.finish()
        }
    }

    private func drain(_ stream: AsyncThrowingStream<Generation, Error>) async throws {
        for try await _ in stream {}
    }

    private func completion(_ reason: GenerateStopReason) -> Generation {
        .info(GenerateCompletionInfo(promptTokenCount: 2, generationTokenCount: 3,
                                     promptTime: 0, generationTime: 0, stopReason: reason))
    }
}
