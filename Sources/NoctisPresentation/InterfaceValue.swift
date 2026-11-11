// Created by Sébastien DAGUIN

import Foundation

/// A JSON-compatible value used for validated node properties.
///
/// The interface description is structured data produced by the model and consumed
/// by the engine. A generic value keeps the schema serializable without making the
/// domain depend on any renderer; the validator constrains which keys and value
/// kinds each node type accepts.
public enum InterfaceValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([InterfaceValue])
    case object([String: InterfaceValue])
    case null
}

extension InterfaceValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([InterfaceValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: InterfaceValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported InterfaceValue payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
