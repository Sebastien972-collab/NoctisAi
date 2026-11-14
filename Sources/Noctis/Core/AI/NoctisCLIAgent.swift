// Created by Sébastien DAGUIN
import Foundation
import MLXLMCommon
import os

private struct NoctisToolContext: ToolContext {
    let dispatcher: NoctisToolDispatcher
    let trace: AgentTraceScope
}

private struct NoctisDynamicTool: AnyTool {
    typealias Context = NoctisToolContext

    let entry: NoctisToolRegistry.Entry
    let parametersSchema: JSONSchema

    var name: String { entry.name }
    var description: String { entry.description }
    var isReadOnly: Bool { true }
    var isConcurrencySafe: Bool { false }

    func execute(arguments: Data, context: NoctisToolContext) async throws -> ToolResult {
        throw AgentError.invalidToolCall
    }

    func execute(call: ToolCall, context: NoctisToolContext) async throws -> ToolResult {
        let started = ContinuousClock.now
        do {
            guard call.name == name, NoctisLLMClient.isValidCallID(call.id),
                  let object = try JSONSerialization.jsonObject(with: call.argumentsData) as? [String: String],
                  case let .object(properties, required, _) = parametersSchema,
                  Set(object.keys).isSubset(of: Set(properties.keys)),
                  required.allSatisfy({ object[$0] != nil }) else { throw AgentError.invalidArguments }
            context.trace.tool(call, status: .validated)
            context.trace.tool(call, status: .executing)
            let mlxCall = MLXLMCommon.ToolCall(
                function: .init(name: name, arguments: object.mapValues { .string($0) }), id: call.id
            )
            let content = try await context.dispatcher.execute(mlxCall)
            context.trace.tool(call, status: .succeeded, duration: ContinuousClock.now - started)
            return ToolResult(content: content)
        } catch {
            let reason = AgentTraceEvent.Reason.classify(error)
            let status: AgentToolTrace.Status = reason == .cancelled ? .cancelled
                : (reason == .permissionDenied || reason == .invalidArguments ? .refused : .failed)
            context.trace.tool(call, status: status, duration: ContinuousClock.now - started, reason: reason)
            if error is CancellationError { throw CancellationError() }
            // The error result goes back to the model, but no raw error is retained in traces.
            return .error(reason == .permissionDenied ? "Action refusée : permission insuffisante" : "Échec de l’outil")
        }
    }
}

/// CLI-facing AgentLoop wrapper. It owns no model and only references the loaded MLX worker.
public final class NoctisCLIAgent: Sendable {
    private let agent: Agent<NoctisToolContext>
    private let client: NoctisLLMClient
    private let registry: NoctisToolRegistry
    private let web: WebToolDispatcher
    public let traceRecorder: AgentTraceRecorder
    private struct State {
        var running = false
        var recoveryHistory: [ChatMessage]?
        var lastRunID: RunID?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public var recoveryHistory: [ChatMessage]? { state.withLock { $0.recoveryHistory } }

    public func endSession() {
        if let runID = state.withLock({ $0.lastRunID }) {
            traceRecorder.record(runID: runID, kind: .sessionEnded)
        }
    }

    init(client: NoctisLLMClient, registry: NoctisToolRegistry, web: WebToolDispatcher,
         traceRecorder: AgentTraceRecorder = AgentTraceRecorder()) {
        self.client = client
        self.registry = registry
        self.web = web
        self.traceRecorder = traceRecorder
        let tools = registry.entries.map { entry in
            NoctisDynamicTool(entry: entry, parametersSchema: Self.schemaFromToolSpec(entry.schema))
        }
        agent = Agent(client: client, tools: tools, configuration: AgentConfiguration(
            maxIterations: 8,
            toolTimeout: .seconds(30),
            maxToolResultCharacters: 262_144
        ))
    }

    public func stream(
        prompt: String,
        history: [ChatMessage] = []
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let acquired = state.withLock { state in
            guard !state.running else { return false }
            state.running = true
            state.recoveryHistory = nil
            return true
        }
        guard acquired else {
            return AsyncThrowingStream { $0.finish(throwing: MLXModelServiceError.generationInProgress) }
        }
        let runID = RunID()
        state.withLock { $0.lastRunID = runID }
        let trace = AgentTraceScope(recorder: traceRecorder, runID: runID)
        let context = NoctisToolContext(dispatcher: NoctisToolDispatcher(registry: registry, web: web,
            userPrompt: prompt), trace: trace)
        var requestContext = RequestContext(onStreamEvent: { event in
            if case let .toolCallStarted(name, id) = event.kind,
               self.registry.permits(name), NoctisLLMClient.isValidCallID(id) {
                trace.tool(ToolCall(id: id, name: name, arguments: ""), status: .requested)
            }
        })
        let lease: UUID
        do { lease = try client.beginRun() } catch {
            state.withLock { $0.running = false }
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        requestContext.modelLease = lease
        requestContext.agentTrace = trace
        let options = InvocationOptions(tokenBudget: nil, requestContext: requestContext,
                                        systemPromptOverride: nil, approvalHandler: nil,
                    sessionID: SessionID(), runID: runID)
        return AsyncThrowingStream { output in
            let task = Task {
                await perform(prompt: prompt, history: history, context: context, options: options, output: output)
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(prompt: String, history: [ChatMessage], context: NoctisToolContext,
                         options: InvocationOptions,
                         output: AsyncThrowingStream<StreamEvent, Error>.Continuation) async {
        let trace = context.trace
        trace.record(.runStarted)
        var resolved = history + [.user(prompt)]
        var pending: [ChatMessage]?
        var completed = false
        let (events, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let run = Task {
            do {
                try await agent.performStream(userMessage: .user(prompt), history: history,
                                              context: context, options: options, continuation: continuation)
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in run.cancel() }
        do {
            for try await event in events {
                try Task.checkCancellation()
                switch event.kind {
                case .iterationCompleted(_, _, let messages): pending = messages
                case .toolCallCompleted(let id, let name, let result):
                    pending?.append(.tool(id: id, name: name, content: result.content))
                    if let candidate = pending, (try? candidate.validateForAgentHistory()) != nil {
                        resolved = candidate
                    }
                case .finished(_, _, let reason, let messages):
                    completed = reason == .completed
                    state.withLock { $0.recoveryHistory = messages }
                default: break
                }
                output.yield(event)
            }
            try Task.checkCancellation()
            await run.value
            trace.record(completed ? .runCompleted : .runFailed)
            if let lease = options.requestContext?.modelLease { client.endRun(lease) }
            state.withLock { $0.running = false }
            output.finish()
        } catch {
            run.cancel()
            await run.value
            resolved = recoveredHistory(pending: pending, resolved: resolved, history: history, error: error)
            let recovery = resolved
            state.withLock { $0.recoveryHistory = recovery }
            trace.record(error is CancellationError ? .runCancelled : .runFailed,
                         reason: AgentTraceEvent.Reason.classify(error))
            if let lease = options.requestContext?.modelLease { client.endRun(lease) }
            state.withLock { $0.running = false }
            output.finish(throwing: error)
        }
    }

    private func recoveredHistory(pending: [ChatMessage]?, resolved: [ChatMessage],
                                  history: [ChatMessage], error: any Error) -> [ChatMessage] {
        var resolved = resolved
        if var candidate = pending,
           let callIndex = candidate.lastIndex(where: {
            if case .assistant(let message) = $0 { return !message.toolCalls.isEmpty }
            return false
           }), case .assistant(let message) = candidate[callIndex] {
            let completed = Set(candidate.dropFirst(callIndex + 1).compactMap { item -> String? in
                if case .tool(let id, _, _) = item { return id }
                return nil
            })
            for call in message.toolCalls where !completed.contains(call.id) {
                candidate.append(.tool(id: call.id, name: call.name,
                                       content: "Action interrompue ; aucun résultat confirmé."))
            }
            if (try? candidate.validateForAgentHistory()) != nil { resolved = candidate }
        }
        // Keep completed tool exchanges. An explicit interruption turn restores
        // strict user/assistant alternation without discarding the conversation.
        let rejectedContext = error as? MLXModelServiceError == .contextLimit && pending == nil
        if rejectedContext { resolved = history }
        if rejectedContext {
            // The refused input never becomes part of the accepted conversation.
        } else if case .assistant(let message) = resolved.last, message.toolCalls.isEmpty {
            // A complete ordinary response already closes this turn.
        } else {
            resolved.append(.assistant(AssistantMessage(content: "Réponse interrompue avant la fin.")))
        }
        return resolved
    }

    private static func schemaFromToolSpec(_ spec: ToolSpec) -> JSONSchema {
        let function = spec["function"] as? [String: any Sendable] ?? [:]
        let parameters = function["parameters"] as? [String: any Sendable] ?? [:]
        return schema(parameters)
    }

    private static func schema(_ value: [String: any Sendable]) -> JSONSchema {
        let type = value["type"] as? String
        let description = value["description"] as? String
        switch type {
        case "string":
            return .string(description: description)
        case "integer":
            return .integer(description: description)
        case "number":
            return .number(description: description)
        case "boolean":
            return .boolean(description: description)
        case "array":
            let items = value["items"] as? [String: any Sendable] ?? [:]
            return .array(items: schema(items), description: description)
        case "object":
            let rawProperties = value["properties"] as? [String: any Sendable] ?? [:]
            let properties = rawProperties.reduce(into: [String: JSONSchema]()) { result, item in
                if let property = item.value as? [String: any Sendable] {
                    result[item.key] = schema(property)
                }
            }
            let required = value["required"] as? [String] ?? []
            return .object(properties: properties, required: required, description: description)
        default:
            return .object(properties: [:], required: [], description: description)
        }
    }
}
