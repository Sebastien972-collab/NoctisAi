// Created by Sébastien DAGUIN

import Foundation

/// The complete, versioned description of an interface produced by the model and
/// validated by the engine. The root node is the single entry point of the tree.
public struct InterfaceDescription: Codable, Sendable, Equatable {
    /// Current schema version. Increment it when the node model changes in a
    /// way that existing descriptions or prompts can no longer be read safely.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let revision: Int
    public let id: String
    public var title: String?
    public var root: InterfaceNode

    public init(
        schemaVersion: Int = currentSchemaVersion,
        revision: Int = 1,
        id: String,
        title: String? = nil,
        root: InterfaceNode
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.id = id
        self.title = title
        self.root = root
    }
}
