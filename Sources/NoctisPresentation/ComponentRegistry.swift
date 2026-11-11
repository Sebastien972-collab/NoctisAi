import Foundation

public struct ComponentDefinition: Sendable, Equatable {
    public let type: InterfaceNodeType
    public let requiredProperties: Set<String>
    public let allowedProperties: Set<String>

    public init(type: InterfaceNodeType, requiredProperties: Set<String> = [], allowedProperties: Set<String> = []) {
        self.type = type
        self.requiredProperties = requiredProperties
        self.allowedProperties = allowedProperties
    }
}

/// Renderer-independent allowlist. Platform renderers decide how an approved type looks.
public struct ComponentRegistry: Sendable {
    private let definitions: [InterfaceNodeType: ComponentDefinition]

    public init(definitions: [ComponentDefinition] = ComponentRegistry.standardDefinitions) {
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.type, $0) })
    }

    public subscript(type: InterfaceNodeType) -> ComponentDefinition? { definitions[type] }

    public static let standardDefinitions: [ComponentDefinition] = InterfaceNodeType.allCases.map { type in
        switch type {
        case .text, .heading, .markdown, .status:
            ComponentDefinition(type: type, requiredProperties: ["value"], allowedProperties: ["value"])
        case .progress:
            ComponentDefinition(type: type, requiredProperties: ["value"], allowedProperties: ["value", "label"])
        case .input:
            ComponentDefinition(type: type, allowedProperties: ["placeholder", "value"])
        case .chart:
            ComponentDefinition(type: type, allowedProperties: ["title", "values", "labels"])
        default:
            ComponentDefinition(type: type, allowedProperties: ["title", "value", "label", "selected"])
        }
    }
}
