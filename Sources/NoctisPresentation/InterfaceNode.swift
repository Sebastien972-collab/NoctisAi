// Created by Sébastien DAGUIN

import Foundation

/// One node of the declarative interface tree.
///
/// A node has a stable identifier, a known type, validated properties, an
/// optional style, children when its type allows them, and allowed actions.
/// The engine validates and stores these trees; a renderer turns them into
/// terminal output. Nodes are pure data: they never contain Swift code.
public struct InterfaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let type: InterfaceNodeType
    public var properties: [String: InterfaceValue]
    public var style: InterfaceStyle?
    public var children: [InterfaceNode]
    public var actions: [InterfaceAction]

    public init(
        id: String,
        type: InterfaceNodeType,
        properties: [String: InterfaceValue] = [:],
        style: InterfaceStyle? = nil,
        children: [InterfaceNode] = [],
        actions: [InterfaceAction] = []
    ) {
        self.id = id
        self.type = type
        self.properties = properties
        self.style = style
        self.children = children
        self.actions = actions
    }

    /// Convenience for a leaf text node, the most common primitive.
    public static func text(_ id: String, _ value: String) -> InterfaceNode {
        InterfaceNode(id: id, type: .text, properties: ["value": .string(value)])
    }
}
