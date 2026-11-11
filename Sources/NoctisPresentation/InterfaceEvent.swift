// Created by Sébastien DAGUIN

import Foundation

/// Runtime signals raised by the user or the interface lifecycle. These are not
/// part of the declarative description: they flow the opposite direction, from
/// the terminal back to the presentation engine (and possibly to the model).
public enum InterfaceEvent: Sendable, Equatable {
    case actionTriggered(nodeID: String, actionID: String)
    case inputSubmitted(nodeID: String, text: String)
    case selectionChanged(nodeID: String, index: Int)
    case dismissed(id: String)
}
