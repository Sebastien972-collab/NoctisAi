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
            if error is MLXModelServiceError { throw error }
            // The error result goes back to the model, but no raw error is retained in traces.
            return .error(reason == .permissionDenied ? "Action refusée : permission insuffisante" : "Échec de l’outil")
        }
    }
}

/// AgentLoop wrapper that shares the loaded provider's generation lease.
public final class NoctisCLIAgent: Sendable {
    private let agent: Agent<NoctisToolContext>
    private let client: any NoctisAgentLLMClient
    private let registry: NoctisToolRegistry
    private let web: WebToolDispatcher
    public let traceRecorder: AgentTraceRecorder
    private struct State {
        var task: Task<Void, Never>?
        var ended = false
        var recoveryHistory: [ChatMessage]?
        var lastRunID: RunID?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public var recoveryHistory: [ChatMessage]? { state.withLock { $0.recoveryHistory } }

    /// Waits for tool execution and history recovery after cancellation.
    public func settledHistory() async -> [ChatMessage]? {
        let task = state.withLock { $0.task }
        await task?.value
        return recoveryHistory
    }

    public func endSession() {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard !state.ended else { return nil }
            state.ended = true
            if let runID = state.lastRunID {
                traceRecorder.record(runID: runID, kind: .sessionEnded)
            }
            return state.task
        }
        task?.cancel()
    }

    init(client: any NoctisAgentLLMClient, registry: NoctisToolRegistry, web: WebToolDispatcher,
         traceRecorder: AgentTraceRecorder = AgentTraceRecorder(),
         configuration: AgentConfiguration = AgentConfiguration(
             maxIterations: 8, toolTimeout: .seconds(30), maxToolResultCharacters: 262_144
         )) {
        self.client = client
        self.registry = registry
        self.web = web
        self.traceRecorder = traceRecorder
        let tools = registry.entries.map { entry in
            NoctisDynamicTool(entry: entry, parametersSchema: Self.schemaFromToolSpec(entry.schema))
        }
        agent = Agent(client: client, tools: tools, configuration: configuration)
    }

    public func stream(
        prompt: String,
        history: [ChatMessage] = []
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { output in
            state.withLock { state in
                guard !state.ended else {
                    output.finish(throwing: MLXModelServiceError.sessionInvalidated)
                    return
                }
                guard state.task == nil else {
                    output.finish(throwing: MLXModelServiceError.generationInProgress)
                    return
                }
                let lease: UUID
                do { lease = try client.beginRun() } catch {
                    output.finish(throwing: error)
                    return
                }
                let runID = RunID()
                state.lastRunID = runID
                state.recoveryHistory = nil
                let task = Task {
                    await run(prompt: prompt, history: history, runID: runID, lease: lease, output: output)
                }
                state.task = task
                output.onTermination = { _ in task.cancel() }
            }
        }
    }

    private typealias Output = AsyncThrowingStream<StreamEvent, Error>.Continuation

    private func run(prompt: String, history: [ChatMessage], runID: RunID, lease: UUID, output: Output) async {
        let trace = AgentTraceScope(recorder: traceRecorder, runID: runID)
        let options = invocation(trace: trace, runID: runID, lease: lease)
        let context = NoctisToolContext(dispatcher: NoctisToolDispatcher(registry: registry, web: web,
                                                                      userPrompt: prompt), trace: trace)
        let (events, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        trace.record(.runStarted)
        let producer = Task {
            do {
                try Task.checkCancellation()
                try await agent.performStream(userMessage: .user(prompt), history: history,
                                              context: context, options: options, continuation: continuation)
            } catch { continuation.finish(throwing: error) }
        }
        // Drain already committed events on cancellation (a completed tool result belongs to this turn).
        let consumer = Task {
            var transcript = RunTranscript(initial: history + [.user(prompt)])
            do {
                for try await event in events {
                    transcript.observe(event)
                    output.yield(event)
                }
                return (transcript, nil as (any Error)?)
            } catch { return (transcript, error) }
        }
        let (observed, failure) = await withTaskCancellationHandler {
            await consumer.value
        } onCancel: {
            producer.cancel()
        }
        await producer.value
        let error = failure ?? (Task.isCancelled && observed.final == nil ? CancellationError() : nil)
        let rejected = error as? MLXModelServiceError == .contextLimit || error as? AgentError == .contextLimit
        let recovered = rejected ? history : observed.final ?? observed.interrupted(error: error)
        if let error {
            trace.record(error is CancellationError ? .runCancelled : .runFailed,
                         reason: AgentTraceEvent.Reason.classify(error))
        } else { trace.record(observed.completed ? .runCompleted : .runFailed) }
        await client.endRun(lease)
        state.withLock {
            $0.recoveryHistory = recovered
            $0.task = nil
        }
        output.finish(throwing: error)
    }

    private func invocation(trace: AgentTraceScope, runID: RunID, lease: UUID) -> InvocationOptions {
        var context = RequestContext(onStreamEvent: { event in
            if case let .toolCallStarted(name, id) = event.kind,
               self.registry.permits(name), NoctisLLMClient.isValidCallID(id) {
                trace.tool(ToolCall(id: id, name: name, arguments: ""), status: .requested)
            }
        })
        context.modelLease = lease
        context.agentTrace = trace
        return InvocationOptions(tokenBudget: nil, requestContext: context,
                                 systemPromptOverride: nil, approvalHandler: nil, sessionID: SessionID(), runID: runID)
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
