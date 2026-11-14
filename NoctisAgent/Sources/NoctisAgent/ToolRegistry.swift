// Created by Sébastien DAGUIN

import Foundation

public struct AgentToolSchema: Sendable {
    public let name: String
    public let description: String
    public let properties: [String: String]
    public let required: [String]
}

public struct ToolRegistry: Sendable {
    private let workspace: AuthorizedWorkspace
    private let withAccess: @Sendable (@Sendable () throws -> String) throws -> String

    /// Construct only after the host has obtained explicit authorization for this directory.
    public init(workspace: AuthorizedWorkspace) {
        self.workspace = workspace
        withAccess = { try $0() }
    }

    package init(workspace: AuthorizedWorkspace,
                 withAccess: @escaping @Sendable (@Sendable () throws -> String) throws -> String) {
        self.workspace = workspace
        self.withAccess = withAccess
    }

    public var schemas: [AgentToolSchema] {
        [
            .init(name: "listFiles", description: "List one directory inside the authorized workspace.",
                  properties: ["path": "Relative directory path; use . for the root."], required: ["path"]),
            .init(name: "readFile", description: "Read a UTF-8 regular file, up to 64 KiB.",
                  properties: ["path": "Relative file path."], required: ["path"]),
            .init(name: "searchCode", description: "Bounded recursive literal, case-sensitive line search.",
                  properties: ["path": "Relative directory path.", "query": "Nonempty literal text."],
                  required: ["path", "query"])
        ]
    }

    public func execute(_ call: AgentToolCall) throws -> String {
        try withAccess { try executeAuthorized(call) }
    }

    private func executeAuthorized(_ call: AgentToolCall) throws -> String {
        try Task.checkCancellation()
        do {
            guard let schema = schemas.first(where: { $0.name == call.name }) else {
                throw AgentError.unsupportedTool
            }
            guard Set(call.arguments.keys) == Set(schema.required),
                  call.arguments.values.allSatisfy({ $0.utf8.count <= 4_096 }),
                  let path = call.arguments["path"] else { throw AgentError.invalidArguments }
            let result: String
            switch call.name {
            case "listFiles": result = try workspace.listFiles(path: path)
            case "readFile": result = try workspace.readFile(path: path)
            case "searchCode":
                guard let query = call.arguments["query"], !query.isEmpty,
                      query.utf8.count <= 256, !query.contains("\n"), !query.contains("\0") else {
                    throw AgentError.invalidArguments
                }
                result = try workspace.searchCode(path: path, query: query)
            default: throw AgentError.unsupportedTool
            }
            guard result.utf8.count <= 98_304 else { throw AgentError.responseLimit }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not echo host paths or unbounded system/model error descriptions.
            return try Self.json(["error": (error as? AgentError ?? .ioFailure).rawValue])
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw AgentError.invalidUTF8
        }
        return text
    }
}
