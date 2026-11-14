// Created by Sébastien DAGUIN

import Foundation

extension Agent {
    func run(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        systemPromptOverride: String?,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AgentResult {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: nil,
            systemPromptOverride: systemPromptOverride, approvalHandler: approvalHandler
        )
        return try await run(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }

    func run(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        options: InvocationOptions
    ) async throws -> AgentResult {
        validateInvocation(options)
        var state = AgentLoopState(messages: initialMessages(
            systemPrompt: options.systemPromptOverride ?? configuration.systemPrompt,
            history: history, userMessage: userMessage
        ))
        try state.messages.validateForAgentHistory()

        var totalUsage = TokenUsageTotals()
        var lastTotalTokens: Int?
        var compactor = ContextCompactor(client: client, configuration: configuration)
        state.budgetPhase = try makeBudgetPhase()

        for iteration in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            let response = try await executeRunIteration(
                messages: &state.messages,
                totalUsage: &totalUsage,
                lastTotalTokens: &lastTotalTokens,
                compactor: &compactor,
                historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
                requestContext: options.requestContext
            )

            if let terminalResult = try await resolveRunIteration(
                response: response,
                context: context,
                iteration: iteration,
                totalUsage: totalUsage,
                options: options,
                state: &state
            ) {
                return terminalResult
            }
        }

        return makeTerminalResult(
            reason: .maxIterationsReached(limit: configuration.maxIterations),
            tokenUsage: totalUsage,
            iterations: configuration.maxIterations,
            history: state.messages
        )
    }

    func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        systemPromptOverride: String?,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: nil,
            systemPromptOverride: systemPromptOverride, approvalHandler: approvalHandler,
            sessionID: sessionID ?? SessionID(), runID: RunID()
        )
        return stream(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }
}

extension Agent {
    func stream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        options: InvocationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        validateInvocation(options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        userMessage: userMessage,
                        history: history,
                        context: context,
                        options: options,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func performStream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var state = AgentLoopState(messages: initialMessages(
            systemPrompt: options.systemPromptOverride ?? configuration.systemPrompt,
            history: history, userMessage: userMessage
        ))
        try state.messages.validateForAgentHistory()
        state.budgetPhase = try makeBudgetPhase()
        try await performStreamLoop(
            state: &state, startIteration: 1,
            totalUsage: TokenUsageTotals(), lastTotalTokens: nil,
            context: context, options: options,
            continuation: continuation
        )
    }

    // Keep the existing explicit execution contract without an unrelated API change.
    // swiftlint:disable:next function_parameter_count
    func performStreamLoop(
        state: inout AgentLoopState,
        startIteration: Int,
        totalUsage: TokenUsageTotals,
        lastTotalTokens: Int?,
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var totalUsage = totalUsage
        var lastTotalTokens = lastTotalTokens
        let processor = StreamProcessor(
            client: client, toolDefinitions: toolDefinitions, policy: .agent(completionPolicy),
            eventFactory: options.eventFactory
        )
        var compactor = ContextCompactor(client: client, configuration: configuration)

        let iterationContext = StreamIterationContext(
            processor: processor, context: context, options: options, continuation: continuation
        )
        guard startIteration <= configuration.maxIterations else {
            finishStreaming(
                continuation: continuation,
                event: makeFinishedEvent(
                    tokenUsage: totalUsage, content: nil,
                    reason: .maxIterationsReached(limit: configuration.maxIterations),
                    history: state.messages, eventFactory: options.eventFactory
                )
            )
            return
        }
        for iterationNumber in startIteration ... configuration.maxIterations {
            try Task.checkCancellation()
            let isFinished = try await runStreamIteration(
                iterationNumber: iterationNumber,
                state: &state, totalUsage: &totalUsage,
                lastTotalTokens: &lastTotalTokens,
                compactor: &compactor,
                iterationContext: iterationContext
            )
            if isFinished { return }
        }

        finishStreaming(
            continuation: continuation,
            event: makeFinishedEvent(
                tokenUsage: totalUsage, content: nil,
                reason: .maxIterationsReached(limit: configuration.maxIterations),
                history: state.messages, eventFactory: options.eventFactory
            )
        )
    }

    struct StreamIterationContext {
        let processor: StreamProcessor
        let context: C
        let options: InvocationOptions
        let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    }

    // Keep the existing explicit execution contract without an unrelated API change.
    // swiftlint:disable:next function_parameter_count
    private func runStreamIteration(
        iterationNumber: Int,
        state: inout AgentLoopState,
        totalUsage: inout TokenUsageTotals,
        lastTotalTokens: inout Int?,
        compactor: inout ContextCompactor,
        iterationContext: StreamIterationContext
    ) async throws -> Bool {
        let factory = iterationContext.options.eventFactory
        let continuation = iterationContext.continuation
        try await compactStreamingMessagesIfNeeded(
            &state.messages,
            totalUsage: &totalUsage,
            lastTotalTokens: lastTotalTokens,
            compactor: &compactor,
            historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
            eventFactory: factory,
            continuation: continuation
        )
        let iteration = try await generateStreamingResponse(
            processor: iterationContext.processor,
            messages: &state.messages,
            totalUsage: &totalUsage,
            compactor: &compactor,
            historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
            continuation: continuation,
            options: iterationContext.options
        )
        state.messages.append(.assistant(iteration.toAssistantMessage()))
        yieldIterationCompleted(
            iteration: iteration, iterationNumber: iterationNumber,
            messages: state.messages, context: iterationContext.context,
            eventFactory: factory, continuation: continuation
        )
        if try await resolveStreamingIteration(
            iteration: iteration, iterationNumber: iterationNumber, totalUsage: totalUsage,
            iterationContext: iterationContext, state: &state
        ) {
            return true
        }
        try await checkpointIfConfigured(
            iterationNumber: iterationNumber, state: state,
            totalUsage: totalUsage, iterationUsage: iteration.usage,
            eventFactory: factory, checkpointer: iterationContext.options.checkpointer
        )
        if finishIfOverBudget(
            iterationContext.options.tokenBudget, totalUsage: totalUsage,
            history: state.messages, eventFactory: factory, continuation: continuation
        ) {
            return true
        }
        lastTotalTokens = iteration.usage?.total
        return false
    }

    func indexedToolCalls(from toolCalls: [ToolCall]) -> [IndexedToolCall] {
        toolCalls.enumerated().map { offset, call in IndexedToolCall(index: offset, call: call) }
    }
}
