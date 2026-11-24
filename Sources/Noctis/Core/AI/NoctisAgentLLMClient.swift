// Created by Sébastien DAGUIN
import Foundation

/// Keeps a generation lease across model turns and the tools executed by AgentLoop.
protocol NoctisAgentLLMClient: ToolCallSurfacingClient, ContentOnlyTerminatingClient {
    func beginRun() throws -> UUID
    func endRun(_ lease: UUID) async
}

extension NoctisLLMClient: NoctisAgentLLMClient {}
