// Created by Sébastien DAGUIN

import Foundation
import NoctisAgent
import MLXLMCommon

final class MLXChatSession: StructuredModelSession {
    private let model: ModelContainer
    private var session: ChatSession
    private let workspaceAccess: WorkspaceToolAccess
    private let webDispatcher: WebToolDispatcher
    private let presentation: NoctisPresentationInstructions
    let profile: MLXModelProfile
    private let toolContinuation = GPTOSSToolContinuation()
    private var additionalInstructions: [String] = []

    init(
        model: ModelContainer, session: ChatSession,
        workspaceAccess: WorkspaceToolAccess, webDispatcher: WebToolDispatcher,
        presentation: NoctisPresentationInstructions, profile: MLXModelProfile
    ) {
        self.model = model
        self.session = session
        self.workspaceAccess = workspaceAccess
        self.webDispatcher = webDispatcher
        self.presentation = presentation
        self.profile = profile
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AIResponseStream.map(streamResponseEvents(to: prompt), transform: AIResponseStream.text).stream
    }

    func streamResponseEvents(to prompt: String) -> AsyncThrowingStream<AIResponseEvent, Error> {
        toolContinuation.invalidate()
        let (stream, output) = AsyncThrowingStream<AIResponseEvent, Error>.makeStream()
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        session.instructions = ([NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation)]
                                    + additionalInstructions).joined(separator: "\n\n")
        session.tools = registry.schemas
        let dispatcher = NoctisToolDispatcher(registry: registry, web: webDispatcher, userPrompt: prompt)
        session.toolDispatch = { call in
            try await Self.dispatch(call, using: dispatcher, output: output)
        }
        session.generateParameters.maxTokens = profile.maximumOutputTokens
        session.generateParameters.toolCallPolicy = .init(recovery: .disabled, validation: .strict)
        let upstream = session.streamDetails(to: prompt)
        let task = Task { [profile] in
            do {
                for try await event in upstream {
                    switch event {
                    case .chunk(let chunk): output.yield(.textDelta(chunk))
                    case .reasoning(let text) where profile != .gptOSS: output.yield(.reasoningDelta(text))
                    case .rejectedToolCall: throw AgentError.invalidToolCall
                    case .info(let info):
                        if info.stopReason == .length { throw MLXModelServiceError.responseLimit }
                        if info.stopReason == .cancelled || info.stopReason == .interrupted {
                            throw CancellationError()
                        }
                    default: break
                    }
                }
                output.finish()
            } catch { output.finish(throwing: error) }
        }
        output.onTermination = { _ in task.cancel() }
        return stream
    }

    static func dispatch(
        _ call: MLXLMCommon.ToolCall, using dispatcher: NoctisToolDispatcher,
        output: AsyncThrowingStream<AIResponseEvent, Error>.Continuation
    ) async throws -> String {
        try Task.checkCancellation()
        let id = call.id ?? UUID().uuidString
        let name = call.function.name
        let data = try JSONSerialization.data(withJSONObject: call.function.arguments.mapValues(\.anyValue),
                                              options: [.sortedKeys])
        guard let arguments = String(data: data, encoding: .utf8) else { throw AgentError.invalidArguments }
        if case .terminated = output.yield(.toolStarted(id: id, name: name, arguments: arguments)) {
            throw CancellationError()
        }
        do {
            let result = try await dispatcher.execute(call)
            output.yield(.toolCompleted(id: id, name: name, result: result, isError: false))
            return result
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            output.yield(.toolCompleted(id: id, name: name, result: error.localizedDescription, isError: true))
            throw error
        }
    }

    func synchronize() async { await session.synchronize() }

    func streamDetails(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec],
        instructions: String
    ) -> AsyncThrowingStream<Generation, Error> {
        guard let pending = messages.last else {
            toolContinuation.invalidate()
            return session.streamDetails(to: [])
        }
        let continuation = profile == .gptOSS
            ? toolContinuation.begin(messages: messages, tools: tools, instructions: instructions) : nil
        if continuation?.canReuseSession != true {
            // A new or changed transcript must prefill once. A matching Harmony tool
            // result keeps the live cache, including analysis absent from public history.
            session = ChatSession(
                model,
                instructions: instructions,
                history: Array(messages.dropLast()),
                speculativeDecoding: session.speculativeDecoding,
                generateParameters: session.generateParameters,
                components: session.components,
                processing: session.processing,
                additionalContext: session.additionalContext,
                tools: tools,
                toolDispatch: nil
            )
        }
        // AgentLoop owns every tool execution. MLX must only surface calls.
        session.generateParameters.maxTokens = profile.maximumOutputTokens
        session.generateParameters.toolCallPolicy = .init(recovery: .disabled, validation: .strict)
        let upstream = session.streamDetails(to: [pending])
        guard let continuation else { return upstream }
        return toolContinuation.observe(upstream, request: continuation.request)
    }

    func reset(history: [AIChatMessage]) async throws {
        toolContinuation.invalidate()
        additionalInstructions = []
        let messages: [MLXLMCommon.Chat.Message] = history.compactMap {
            switch $0.role {
            case .user: return .user($0.content)
            case .assistant: return .assistant($0.content)
            case .system:
                additionalInstructions.append($0.content)
                return nil
            }
        }
        // Rebuild the conversation cache while reusing the loaded weights.
        session = ChatSession(
            model,
            instructions: ([NoctisSystemPromptBuilder.build(
                registry: NoctisToolRegistry(workspace: workspaceAccess.registry), presentation: presentation
            )] + additionalInstructions).joined(separator: "\n\n"),
            history: messages,
            speculativeDecoding: session.speculativeDecoding,
            generateParameters: session.generateParameters,
            components: session.components,
            processing: session.processing,
            additionalContext: session.additionalContext,
            tools: session.tools,
            toolDispatch: session.toolDispatch
        )
    }
}
