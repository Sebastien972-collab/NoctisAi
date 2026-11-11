import Foundation

public struct InterfaceValidator: Sendable {
    public let limits: InterfaceLimits
    public let registry: ComponentRegistry

    public init(limits: InterfaceLimits = InterfaceLimits(), registry: ComponentRegistry = ComponentRegistry()) {
        self.limits = limits
        self.registry = registry
    }

    public func decodeAndValidate(_ data: Data) throws -> InterfaceDescription {
        guard data.count <= limits.maximumEncodedBytes else { throw InterfaceValidationError.descriptionTooLarge }
        let description = try JSONDecoder().decode(InterfaceDescription.self, from: data)
        try validate(description)
        return description
    }

    public func validate(_ description: InterfaceDescription) throws {
        guard description.schemaVersion == InterfaceDescription.currentSchemaVersion else {
            throw InterfaceValidationError.unsupportedSchemaVersion
        }
        guard description.revision > 0 else { throw InterfaceValidationError.invalidRevision }
        try validateIdentifier(description.id)
        if let title = description.title { try validateString(title) }
        var identifiers = Set<String>()
        var nodeCount = 0
        try validate(description.root, depth: 1, identifiers: &identifiers, nodeCount: &nodeCount)
    }

    private func validate(
        _ node: InterfaceNode,
        depth: Int,
        identifiers: inout Set<String>,
        nodeCount: inout Int
    ) throws {
        guard depth <= limits.maximumDepth else { throw InterfaceValidationError.tooDeep }
        nodeCount += 1
        guard nodeCount <= limits.maximumNodes else { throw InterfaceValidationError.tooManyNodes }
        try validateIdentifier(node.id)
        guard identifiers.insert(node.id).inserted else { throw InterfaceValidationError.duplicateIdentifier }
        guard let definition = registry[node.type] else { throw InterfaceValidationError.unknownNodeType }
        guard node.children.count <= limits.maximumChildrenPerNode else { throw InterfaceValidationError.tooManyChildren }
        guard node.actions.count <= limits.maximumActionsPerNode else { throw InterfaceValidationError.tooManyActions }
        guard node.type.allowsChildren || node.children.isEmpty else { throw InterfaceValidationError.childrenNotAllowed }
        guard definition.requiredProperties.isSubset(of: node.properties.keys) else {
            throw InterfaceValidationError.missingProperty
        }
        guard Set(node.properties.keys).isSubset(of: definition.allowedProperties) else {
            throw InterfaceValidationError.invalidProperty
        }
        for value in node.properties.values { try validate(value, depth: 1) }
        for action in node.actions {
            try validateIdentifier(action.id)
            try validateString(action.label)
        }
        if let style = node.style {
            let colors = Set(["primary", "secondary", "accent", "success", "warning", "error"])
            if let foreground = style.foreground, !colors.contains(foreground) { throw InterfaceValidationError.invalidStyle }
            if let background = style.background, !colors.contains(background) { throw InterfaceValidationError.invalidStyle }
        }
        for child in node.children {
            try validate(child, depth: depth + 1, identifiers: &identifiers, nodeCount: &nodeCount)
        }
    }

    private func validate(_ value: InterfaceValue, depth: Int) throws {
        guard depth <= limits.maximumDepth else { throw InterfaceValidationError.tooDeep }
        switch value {
        case .string(let string): try validateString(string)
        case .array(let values):
            guard values.count <= limits.maximumChildrenPerNode else { throw InterfaceValidationError.tooManyChildren }
            for value in values { try validate(value, depth: depth + 1) }
        case .object(let values):
            guard values.count <= limits.maximumChildrenPerNode else { throw InterfaceValidationError.tooManyChildren }
            for (key, value) in values { try validateString(key); try validate(value, depth: depth + 1) }
        case .number(let number):
            guard number.isFinite else { throw InterfaceValidationError.invalidProperty }
        case .bool, .null: break
        }
    }

    private func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 128,
              identifier.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0.properties.numericType != nil || "-_.".unicodeScalars.contains($0) })
        else { throw InterfaceValidationError.emptyIdentifier }
    }

    private func validateString(_ string: String) throws {
        guard string.utf8.count <= limits.maximumStringBytes, !string.contains("\0") else {
            throw InterfaceValidationError.invalidProperty
        }
    }
}
