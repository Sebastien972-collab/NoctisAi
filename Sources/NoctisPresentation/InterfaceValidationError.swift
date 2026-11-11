// Created by Sébastien DAGUIN

import Foundation

/// Validation failures for interface descriptions. Following the existing
/// `AgentError` convention, these are stable raw strings surfaced to the model
/// without leaking host paths or internal details.
public enum InterfaceValidationError: String, Error, Sendable, Equatable {
    case unsupportedSchemaVersion
    case emptyIdentifier
    case duplicateIdentifier
    case unknownNodeType
    case missingProperty
    case invalidProperty
    case childrenNotAllowed
    case tooManyChildren
    case tooManyNodes
    case descriptionTooLarge
    case invalidActionReference
    case invalidStyle
    case invalidRevision
    case targetNotFound
    case incompatibleMutation
    case tooDeep
    case tooManyActions
}
