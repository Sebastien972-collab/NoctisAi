// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon
import NoctisAgent
import os

public typealias AgentRunID = RunID

/// Metadata only: never stores arguments, prompts, error descriptions or result bodies.
public struct AgentToolTrace: Sendable {
    public enum Status: String, Sendable {
        case requested, validated, executing, succeeded, failed, refused, cancelled
    }
    public enum Result: String, Sendable {
        case notObserved, observedSuccess, observedFailure
    }
    public let callID: String
    public let tool: String
    public let status: Status
    public let duration: Duration?
    public let result: Result
    public let reason: AgentTraceEvent.Reason?
}

public struct AgentTraceEvent: Sendable {
    public enum Kind: String, Sendable {
        case runStarted, runCompleted, runFailed, runCancelled, sessionEnded
        case generationStarted, generationCompleted, generationFailed, generationCancelled
        case toolRequested, toolValidated, toolExecuting, toolCompleted, toolRejected
        case serializationFailed, templateFailed
    }
    public enum Reason: Sendable, Equatable {
        case invalidCall, invalidArguments, permissionDenied, executionFailed, cancelled
        case serialization, template
        case rejected(RejectedToolCall.Reason)

        static func classify(_ error: any Error) -> Self {
            if error is CancellationError { return .cancelled }
            if let error = error as? NoctisAgent.AgentError {
                switch error {
                case .accessDenied, .invalidPath, .notRegularFile, .fileTooLarge: return .permissionDenied
                case .invalidArguments: return .invalidArguments
                default: return .executionFailed
                }
            }
            if let error = error as? AgentError {
                if error == .invalidArguments { return .invalidArguments }
                if error == .invalidToolCall { return .invalidCall }
            }
            // Inspect the type only. Error descriptions can contain local or model data.
            if String(reflecting: type(of: error)).contains("TemplateException") { return .template }
            if error is DecodingError || error is EncodingError || (error as NSError).domain == NSCocoaErrorDomain {
                return .serialization
            }
            return .executionFailed
        }
    }
    public let timestamp: Date
    public let runID: AgentRunID
    public let kind: Kind
    public let tool: AgentToolTrace?
    public let reason: Reason?
    /// Additional safe metadata is opt-in; never contains a raw error or model output.
    public let diagnosticCode: String?
}

public final class AgentTraceRecorder: Sendable {
    private struct State {
        var events: [AgentTraceEvent] = []
        var diagnosticsEnabled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public let capacity: Int

    public init(capacity: Int = 256) { self.capacity = max(1, min(capacity, 4_096)) }

    public var diagnosticsEnabled: Bool {
        get { state.withLock { $0.diagnosticsEnabled } }
        set { state.withLock { $0.diagnosticsEnabled = newValue } }
    }

    public func events(for runID: AgentRunID? = nil) -> [AgentTraceEvent] {
        state.withLock { state in state.events.filter { runID == nil || $0.runID == runID } }
    }

    public func clear() { state.withLock { $0.events.removeAll(keepingCapacity: true) } }

    func record(runID: AgentRunID, kind: AgentTraceEvent.Kind,
                tool: AgentToolTrace? = nil, reason: AgentTraceEvent.Reason? = nil) {
        state.withLock { state in
            state.events.append(AgentTraceEvent(
                timestamp: Date(), runID: runID, kind: kind, tool: tool, reason: reason,
                diagnosticCode: state.diagnosticsEnabled ? kind.rawValue : nil
            ))
            if state.events.count > capacity { state.events.removeFirst(state.events.count - capacity) }
        }
    }
}

struct AgentTraceScope: Sendable {
    let recorder: AgentTraceRecorder
    let runID: AgentRunID

    func record(_ kind: AgentTraceEvent.Kind, reason: AgentTraceEvent.Reason? = nil) {
        recorder.record(runID: runID, kind: kind, reason: reason)
        if reason == .serialization { recorder.record(runID: runID, kind: .serializationFailed, reason: reason) }
        if reason == .template { recorder.record(runID: runID, kind: .templateFailed, reason: reason) }
    }

    func tool(_ call: ToolCall, status: AgentToolTrace.Status, duration: Duration? = nil,
              reason: AgentTraceEvent.Reason? = nil) {
        let kind: AgentTraceEvent.Kind
        switch status {
        case .requested: kind = .toolRequested
        case .validated: kind = .toolValidated
        case .executing: kind = .toolExecuting
        case .succeeded, .failed, .cancelled: kind = .toolCompleted
        case .refused: kind = .toolRejected
        }
        recorder.record(runID: runID, kind: kind, tool: AgentToolTrace(
            callID: call.id, tool: call.name, status: status, duration: duration,
            result: status == .succeeded ? .observedSuccess
                : (status == .failed ? .observedFailure : .notObserved), reason: reason
        ), reason: reason)
    }
}
