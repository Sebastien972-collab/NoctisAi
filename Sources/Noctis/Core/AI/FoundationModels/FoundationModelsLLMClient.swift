// Created by Sébastien DAGUIN
#if os(iOS) && canImport(FoundationModels)
import Foundation
import FoundationModels

/// iOS on-device provider. It proposes structured calls and never executes tools.
@available(iOS 26.0, *)
public final class FoundationModelsLLMClient: ToolCallSurfacingClient, ContentOnlyTerminatingClient, Sendable {
    private let systemPrompt: String
    private let access: ModelGenerationAccess
    private let revision: Int
    private let instructions: (@Sendable () -> String)?
    private let producers = FoundationModelsRunTasks()

    public convenience init(systemPrompt: String) {
        self.init(systemPrompt: systemPrompt, access: ModelGenerationAccess())
    }

    init(systemPrompt: String, access: ModelGenerationAccess, instructions: (@Sendable () -> String)? = nil) {
        self.systemPrompt = systemPrompt
        self.access = access
        self.revision = access.revision
        self.instructions = instructions
    }

    public var contextWindowSize: Int? { 4_096 }
    public var providerIdentifier: ProviderIdentifier { .foundationModels }
    func beginRun() throws -> UUID { try access.acquire(revision: revision) }
    func endRun(_ lease: UUID) async {
        await producers.finish(lease)
        access.release(lease)
    }

    public func generate(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
                         requestContext: RequestContext?) async throws -> AssistantMessage {
        var text = ""
        var calls: [ToolCall] = []
        for try await delta in makeStream(messages: messages, tools: tools, responseFormat: responseFormat,
                                          requestContext: requestContext) {
            switch delta {
            case let .content(value): text += value
            case let .toolCallStart(index, id, name, kind):
                guard index == calls.count else { throw AgentError.invalidToolCall }
                calls.append(ToolCall(id: id, name: name, arguments: "", kind: kind))
            case let .toolCallDelta(index, arguments):
                guard calls.indices.contains(index) else { throw AgentError.invalidToolCall }
                let call = calls[index]
                calls[index] = ToolCall(id: call.id, name: call.name, arguments: call.arguments + arguments)
            default: continue
            }
        }
        return AssistantMessage(content: text, toolCalls: calls)
    }

    public func stream(messages: [ChatMessage], tools: [ToolDefinition], requestContext: RequestContext?)
        -> AsyncThrowingStream<StreamDelta, Error> {
        makeStream(messages: messages, tools: tools, responseFormat: nil, requestContext: requestContext)
    }

    private func makeStream(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
                            requestContext: RequestContext?) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                await produce(messages: messages, tools: tools, responseFormat: responseFormat,
                              requestContext: requestContext, output: output)
            }
            if let lease = requestContext?.modelLease { producers.register(task, for: lease) }
            output.onTermination = { _ in task.cancel() }
        }
    }

    private typealias Output = AsyncThrowingStream<StreamDelta, Error>.Continuation

    private func produce(messages: [ChatMessage], tools: [ToolDefinition], responseFormat: ResponseFormat?,
                         requestContext: RequestContext?, output: Output) async {
        let trace = requestContext?.agentTrace
        var lease: UUID?
        defer { if let lease { access.release(lease) } }
        do {
            if let shared = requestContext?.modelLease {
                try access.validate(shared, revision: revision)
            } else {
                lease = try beginRun()
            }
            try Task.checkCancellation()
            let request = try FoundationModelsBridge.prepare(
                messages: messages, tools: tools, context: requestContext, instructions: instructions?() ?? systemPrompt
            )
            if responseFormat != nil, !request.selection.tools.isEmpty {
                throw FoundationModelsBridge.unsupported("response formats combined with tools")
            }
            guard case .available = SystemLanguageModel.default.availability else {
                throw TransportError.providerError(provider: .foundationModels, code: "model_unavailable",
                    message: "Le modèle local Apple est indisponible. Sélectionnez le modèle MLX local.")
            }
            // Pin the on-device model explicitly; no cloud model or executable Apple Tool is supplied.
            let session = LanguageModelSession(model: SystemLanguageModel.default) { request.instructions }
            trace?.record(.generationStarted)
            if let responseFormat {
                try await generateFormatted(session: session, prompt: request.prompt, format: responseFormat,
                                            output: output)
            } else if request.selection.tools.isEmpty {
                try await streamText(session: session, prompt: request.prompt, output: output)
            } else {
                try await streamStep(session: session, request: request, output: output)
            }
            try Task.checkCancellation()
            trace?.record(.generationCompleted)
            output.yield(.finished(usage: nil))
            output.yield(.streamClosed(terminalMarkerSeen: true))
            if let lease { access.release(lease) }
            output.finish()
        } catch {
            let failure = Self.mapError(error)
            trace?.record(failure is CancellationError ? .generationCancelled : .generationFailed,
                          reason: AgentTraceEvent.Reason.classify(failure))
            if let lease { access.release(lease) }
            output.finish(throwing: failure)
        }
    }

    private func streamText(session: LanguageModelSession, prompt: String, output: Output) async throws {
        var accumulator = FoundationModelsTextDelta()
        var isComplete = false
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            isComplete = snapshot.rawContent.isComplete
            let delta = try accumulator.append(snapshot: snapshot.content)
            if !delta.isEmpty { output.yield(.content(delta)) }
        }
        guard isComplete else { throw AgentError.responseLimit }
        guard !accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidToolCall
        }
    }

    private func streamStep(session: LanguageModelSession, request: FoundationModelsBridge.PreparedRequest,
                            output: Output) async throws {
        let schema = try FoundationModelsSchema.make(FoundationModelsBridge.stepSchema(for: request.selection))
        var accumulator = FoundationModelsTextDelta()
        var finalContent: GeneratedContent?
        for try await snapshot in session.streamResponse(to: request.prompt, schema: schema) {
            try Task.checkCancellation()
            finalContent = snapshot.content
            if let text = try FoundationModelsBridge.answerSnapshot(
                snapshot.content.jsonString, afterEmittingAnswer: !accumulator.text.isEmpty
            ) {
                guard !request.selection.requiresTool else { throw AgentError.invalidToolCall }
                let delta = try accumulator.append(snapshot: text)
                if !delta.isEmpty { output.yield(.content(delta)) }
            }
        }
        guard let finalContent, finalContent.isComplete else { throw AgentError.responseLimit }
        let response = try FoundationModelsBridge.decodeStep(
            finalContent.jsonString, selection: request.selection, existingCallIDs: request.existingCallIDs
        )
        try Task.checkCancellation()
        if !response.toolCalls.isEmpty {
            guard accumulator.text.isEmpty else {
                throw TransportError.decodingFailed(description: "The local model changed an answer into a tool call")
            }
            for (index, call) in response.toolCalls.enumerated() {
                output.yield(.toolCallStart(index: index, id: call.id, name: call.name, kind: .function))
                output.yield(.toolCallDelta(index: index, arguments: call.arguments))
            }
        } else {
            let delta = try accumulator.append(snapshot: response.content)
            if !delta.isEmpty { output.yield(.content(delta)) }
        }
    }

    private func generateFormatted(
        session: LanguageModelSession, prompt: String, format: ResponseFormat, output: Output
    ) async throws {
        let schema = try FoundationModelsSchema.make(format.schema)
        let response = try await session.respond(to: prompt, schema: schema)
        try Task.checkCancellation()
        let content = response.content
        guard content.isComplete else { throw AgentError.responseLimit }
        let value = try FoundationModelsBridge.decode(content.jsonString)
        guard FoundationModelsBridge.matches(value, schema: format.schema) else { throw AgentError.invalidArguments }
        output.yield(.content(try FoundationModelsBridge.json(value)))
    }

    private static func mapError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is AgentError || error is TransportError || error is MLXModelServiceError { return error }
        if #available(iOS 27.0, *), let modelError = error as? LanguageModelError,
           case .contextSizeExceeded = modelError { return AgentError.contextLimit }
        if let generationError = error as? LanguageModelSession.GenerationError {
            return mapGenerationError(generationError)
        }
        return generationFailure
    }

    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> any Error {
        switch error {
        case .exceededContextWindowSize: return AgentError.contextLimit
        case .concurrentRequests: return MLXModelServiceError.generationInProgress
        case .rateLimited: return TransportError.rateLimited(retryAfter: nil)
        case .assetsUnavailable:
            return TransportError.providerError(provider: .foundationModels, code: "assets_unavailable",
                message: "Le modèle local Apple n’est pas encore prêt sur cet appareil.")
        default: return generationFailure
        }
    }

    private static var generationFailure: TransportError {
        TransportError.providerError(provider: .foundationModels, code: "generation_failed",
            message: "Le modèle local Apple n’a pas pu terminer cette réponse.")
    }
}

@available(iOS 26.0, *)
extension FoundationModelsLLMClient: NoctisAgentLLMClient {}
#endif
