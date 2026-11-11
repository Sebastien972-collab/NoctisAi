import Foundation

/// Explicit out-of-band envelope. It is parsed only after the closing marker,
/// never token-by-token, and can contain data but no executable behavior.
public enum GenerativeUIOutput: Codable, Sendable, Equatable {
    case create(InterfaceDescription)
    case mutate(InterfaceMutation)
    case dismiss(InterfaceMutation)

    private enum CodingKeys: String, CodingKey { case operation, interface, mutation }
    private enum Operation: String, Codable { case create, mutate, dismiss }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Operation.self, forKey: .operation) {
        case .create: self = .create(try container.decode(InterfaceDescription.self, forKey: .interface))
        case .mutate: self = .mutate(try container.decode(InterfaceMutation.self, forKey: .mutation))
        case .dismiss: self = .dismiss(try container.decode(InterfaceMutation.self, forKey: .mutation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .create(let interface):
            try container.encode(Operation.create, forKey: .operation)
            try container.encode(interface, forKey: .interface)
        case .mutate(let mutation):
            try container.encode(Operation.mutate, forKey: .operation)
            try container.encode(mutation, forKey: .mutation)
        case .dismiss(let mutation):
            try container.encode(Operation.dismiss, forKey: .operation)
            try container.encode(mutation, forKey: .mutation)
        }
    }
}

public enum GenerativeUIProtocol {
    public static let openingMarker = "<noctis-ui>"
    public static let closingMarker = "</noctis-ui>"

    public static let modelInstruction = """
        Réponds normalement en texte. Seulement si une représentation structurée apporte une valeur claire, ajoute à la toute fin un unique bloc <noctis-ui>JSON</noctis-ui>. Le JSON utilise {"operation":"create","interface":{...}} ou {"operation":"mutate","mutation":{...}}, avec schemaVersion 1 et des identifiants stables. N’ajoute jamais d’action système, de chemin local ou de commande. Une conversation ordinaire ne doit contenir aucun bloc UI.
        """

    public static func decode(_ data: Data, validator: InterfaceValidator = InterfaceValidator()) throws -> GenerativeUIOutput {
        let output = try JSONDecoder().decode(GenerativeUIOutput.self, from: data)
        switch output {
        case .create(let description): try validator.validate(description)
        case .mutate(let mutation), .dismiss(let mutation):
            guard mutation.schemaVersion == InterfaceDescription.currentSchemaVersion else {
                throw InterfaceValidationError.unsupportedSchemaVersion
            }
        }
        return output
    }
}
