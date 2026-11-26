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
    private let profile: MLXModelProfile
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
        toolContinuation.invalidate()
        let registry = NoctisToolRegistry(workspace: workspaceAccess.registry)
        session.instructions = ([NoctisSystemPromptBuilder.build(registry: registry, presentation: presentation)]
                                    + additionalInstructions).joined(separator: "\n\n")
        session.tools = registry.schemas
        let dispatcher = NoctisToolDispatcher(registry: registry, web: webDispatcher, userPrompt: prompt)
        session.toolDispatch = { call in try await dispatcher.execute(call) }
        session.generateParameters.maxTokens = profile.maximumOutputTokens
        session.generateParameters.toolCallPolicy = .init(recovery: .disabled, validation: .strict)
        let upstream = session.streamDetails(to: prompt)
        return AsyncThrowingStream { output in
            let task = Task {
                do {
                    for try await event in upstream {
                        switch event {
                        case .chunk(let chunk): output.yield(chunk)
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
