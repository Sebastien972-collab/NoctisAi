// Created by Sébastien DAGUIN
#if os(iOS) && canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
enum FoundationModelsSchema {
    static func make(_ schema: JSONSchema) throws -> GenerationSchema {
        try GenerationSchema(root: dynamic(schema, name: "NoctisResponse"), dependencies: [])
    }

    private static func dynamic(_ schema: JSONSchema, name: String) throws -> DynamicGenerationSchema {
        switch schema {
        case let .array(items, _):
            return try DynamicGenerationSchema(arrayOf: dynamic(items, name: name + "Item"))
        case let .object(properties, required, description):
            return try object(properties: properties, required: required, description: description, name: name)
        case let .anyOf(choices):
            return try union(choices, name: name)
        default:
            return try primitive(schema)
        }
    }

    private static func primitive(_ schema: JSONSchema) throws -> DynamicGenerationSchema {
        switch schema {
        case let .string(_, values):
            return try string(values)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .null:
            if #available(iOS 26.4, *) { return .null }
            throw FoundationModelsBridge.unsupported("explicit null schemas before iOS 26.4")
        default:
            throw AgentError.invalidArguments
        }
    }

    private static func string(_ values: [String]?) throws -> DynamicGenerationSchema {
        guard let values else { return DynamicGenerationSchema(type: String.self) }
        guard !values.isEmpty else { throw AgentError.invalidArguments }
        return DynamicGenerationSchema(type: String.self, guides: [.anyOf(values)])
    }

    private static func object(properties: [String: JSONSchema], required: [String], description: String?,
                               name: String) throws -> DynamicGenerationSchema {
        guard Set(required).isSubset(of: Set(properties.keys)) else { throw AgentError.invalidArguments }
        // Generate the discriminator before content so answer text can stream immediately.
        let keys = properties.keys.sorted { left, right in
            if left == "kind" { return right != "kind" }
            if right == "kind" { return false }
            return left < right
        }
        let fields = try keys.enumerated().map { index, key in
            guard let value = properties[key] else { throw AgentError.invalidArguments }
            return DynamicGenerationSchema.Property(
                name: key, description: propertyDescription(value),
                schema: try dynamic(value, name: name + "Field\(index)"), isOptional: !required.contains(key)
            )
        }
        return DynamicGenerationSchema(name: name, description: description, properties: fields)
    }

    private static func union(_ choices: [JSONSchema], name: String) throws -> DynamicGenerationSchema {
        guard !choices.isEmpty else { throw AgentError.invalidArguments }
        let alternatives = try choices.enumerated().map { index, choice in
            try dynamic(choice, name: name + "Choice\(index)")
        }
        return DynamicGenerationSchema(name: name, anyOf: alternatives)
    }

    private static func propertyDescription(_ schema: JSONSchema) -> String? {
        switch schema {
        case let .string(description, _), let .integer(description), let .number(description),
             let .boolean(description), let .array(_, description), let .object(_, _, description):
            return description
        case .null, .anyOf:
            return nil
        }
    }
}
#endif
