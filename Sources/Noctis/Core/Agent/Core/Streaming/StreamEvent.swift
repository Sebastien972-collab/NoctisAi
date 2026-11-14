// Created by Sébastien DAGUIN
import Foundation

/// Streamed event envelope with identity, session context, and semantic payload; see <doc:StreamingAndSwiftUI>.
public struct StreamEvent: Sendable, Identifiable {
    public let id: EventID
    public let timestamp: Date
    public let sessionID: SessionID?
    public let runID: RunID?
    public let origin: EventOrigin
    public let kind: Kind

    public init(
        id: EventID = EventID(),
        timestamp: Date = Date(),
        sessionID: SessionID? = nil,
        runID: RunID? = nil,
        origin: EventOrigin = .live,
        kind: Kind
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.runID = runID
        self.origin = origin
        self.kind = kind
    }

    func with(origin: EventOrigin) -> StreamEvent {
        StreamEvent(
            id: id,
            timestamp: timestamp,
            sessionID: sessionID,
            runID: runID,
            origin: origin,
            kind: kind
        )
    }

    /// Semantic event payload independent of envelope identity.
    ///
    /// Equality compares payloads only. For ``subAgentEvent(toolCallId:toolName:event:)``,
    /// nested child envelope metadata is ignored and only the child `kind` participates.
    public enum Kind: Sendable {
        case delta(String)
        case reasoningDelta(String)
        case toolCallStarted(name: String, id: String)
        case toolCallCompleted(id: String, name: String, result: ToolResult)
        case audioData(Data)
        case audioTranscript(String)
        case audioFinished(id: String, expiresAt: Int, data: Data)
        case finished(tokenUsage: TokenUsageTotals, content: String?, reason: FinishReason?, history: [ChatMessage])
        case subAgentStarted(toolCallId: String, toolName: String)
        indirect case subAgentEvent(toolCallId: String, toolName: String, event: StreamEvent)
        case subAgentCompleted(toolCallId: String, toolName: String, result: ToolResult)
        case iterationCompleted(usage: TokenUsage?, iteration: Int, history: [ChatMessage])
        case compacted(totalTokens: Int, windowSize: Int)
        /// Emitted after each provider response when a budget snapshot is available.
        case budgetUpdated(budget: ContextBudget)
        /// Emitted once when the configured soft threshold is crossed.
        case budgetAdvisory(budget: ContextBudget)
        case toolApprovalRequested(ToolApprovalRequest)
        case toolApprovalResolved(toolCallId: String, decision: ToolApprovalDecision)
    }
}

// MARK: - Kind Equatable

extension StreamEvent.Kind: Equatable {
    // swiftlint:disable:next cyclomatic_complexity
    public static func == (lhs: StreamEvent.Kind, rhs: StreamEvent.Kind) -> Bool {
        switch (lhs, rhs) {
        case let (.delta(lhsText), .delta(rhsText)):
            lhsText == rhsText
        case let (.reasoningDelta(lhsText), .reasoningDelta(rhsText)):
            lhsText == rhsText
        case let (.toolCallStarted(lhsName, lhsID), .toolCallStarted(rhsName, rhsID)):
            lhsName == rhsName && lhsID == rhsID
        case let (.toolCallCompleted(lhsID, lhsName, lhsResult), .toolCallCompleted(rhsID, rhsName, rhsResult)):
            lhsID == rhsID && lhsName == rhsName && lhsResult == rhsResult
        case let (.audioData(lhsData), .audioData(rhsData)):
            lhsData == rhsData
        case let (.audioTranscript(lhsText), .audioTranscript(rhsText)):
            lhsText == rhsText
        case let (.audioFinished(lhsID, lhsExpires, lhsData), .audioFinished(rhsID, rhsExpires, rhsData)):
            lhsID == rhsID && lhsExpires == rhsExpires && lhsData == rhsData
        case let (.finished(lhsUsage, lhsContent, lhsReason, lhsHistory),
                  .finished(rhsUsage, rhsContent, rhsReason, rhsHistory)):
            lhsUsage == rhsUsage && lhsContent == rhsContent && lhsReason == rhsReason && lhsHistory == rhsHistory
        case let (.subAgentStarted(lhsID, lhsName), .subAgentStarted(rhsID, rhsName)):
            lhsID == rhsID && lhsName == rhsName
        case let (.subAgentEvent(lhsID, lhsName, lhsEvent), .subAgentEvent(rhsID, rhsName, rhsEvent)):
            lhsID == rhsID && lhsName == rhsName && lhsEvent.kind == rhsEvent.kind
        case let (.subAgentCompleted(lhsID, lhsName, lhsResult), .subAgentCompleted(rhsID, rhsName, rhsResult)):
            lhsID == rhsID && lhsName == rhsName && lhsResult == rhsResult
        case let (.iterationCompleted(lhsUsage, lhsIter, lhsHistory),
                  .iterationCompleted(rhsUsage, rhsIter, rhsHistory)):
            lhsUsage == rhsUsage && lhsIter == rhsIter && lhsHistory == rhsHistory
        case let (.compacted(lhsTokens, lhsWindow), .compacted(rhsTokens, rhsWindow)):
            lhsTokens == rhsTokens && lhsWindow == rhsWindow
        case let (.budgetUpdated(lhsBudget), .budgetUpdated(rhsBudget)):
            lhsBudget == rhsBudget
        case let (.budgetAdvisory(lhsBudget), .budgetAdvisory(rhsBudget)):
            lhsBudget == rhsBudget
        case let (.toolApprovalRequested(lhsReq), .toolApprovalRequested(rhsReq)):
            lhsReq == rhsReq
        case let (.toolApprovalResolved(lhsID, lhsDecision), .toolApprovalResolved(rhsID, rhsDecision)):
            lhsID == rhsID && lhsDecision == rhsDecision
        default: false
        }
    }
}
