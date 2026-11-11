import Foundation

public struct InterfaceMutation: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let interfaceID: String
    public let baseRevision: Int
    public let revision: Int
    public let operation: Operation

    public init(schemaVersion: Int = 1, interfaceID: String, baseRevision: Int, revision: Int, operation: Operation) {
        self.schemaVersion = schemaVersion
        self.interfaceID = interfaceID
        self.baseRevision = baseRevision
        self.revision = revision
        self.operation = operation
    }

    public enum Operation: Codable, Sendable, Equatable {
        case update(target: String, properties: [String: InterfaceValue])
        case append(parent: String, node: InterfaceNode)
        case remove(target: String)
        case replace(target: String, node: InterfaceNode)
        case reorder(parent: String, childIDs: [String])
        case dismiss
    }
}
