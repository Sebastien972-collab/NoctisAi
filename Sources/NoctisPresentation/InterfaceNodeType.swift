// Created by Sébastien DAGUIN

import Foundation

/// Primitive component types Noctis can compose into a terminal interface.
///
/// These are the stable building blocks exposed to the model. Noctis assembles
/// them into arbitrary trees instead of having a specialized view per question.
/// Adding or removing a case is a breaking change to the presentation schema and
/// must bump `InterfaceDescription.currentSchemaVersion`.
public enum InterfaceNodeType: String, Codable, Sendable, Equatable, CaseIterable {
    case text
    case row
    case column
    case container
    case divider
    case list
    case table
    case progress
    case spinner
    case input
    case menu
    case status
    case heading
    case markdown
    case card
    case sourceList
    case chart
    case choice
    case confirmation

    /// Whether a node of this type can carry child nodes.
    public var allowsChildren: Bool {
        switch self {
        case .row, .column, .container, .list, .table, .menu, .card, .sourceList, .chart, .choice, .confirmation:
            return true
        case .text, .heading, .markdown, .divider, .progress, .spinner, .input, .status:
            return false
        }
    }

    /// The default arrangement of children for compound types; `nil` for leaves.
    public var defaultLayout: InterfaceLayout? {
        switch self {
        case .row: return .horizontal
        case .column, .container, .list, .table, .menu, .card, .sourceList, .chart, .choice, .confirmation: return .vertical
        case .text, .heading, .markdown, .divider, .progress, .spinner, .input, .status: return nil
        }
    }
}
