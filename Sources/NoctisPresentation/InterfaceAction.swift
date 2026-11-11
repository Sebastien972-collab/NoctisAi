// Created by Sébastien DAGUIN

import Foundation

/// A user-triggerable action attached to a node (for example a menu entry or a
/// selectable list item). The identifier is stable and is reported back through
/// `InterfaceEvent` when the user activates it.
public struct InterfaceAction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
