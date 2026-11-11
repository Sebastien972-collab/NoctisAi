// Created by Sébastien DAGUIN

import Foundation

/// How the children of a compound node are arranged.
public enum InterfaceLayout: String, Codable, Sendable, Equatable, CaseIterable {
    case vertical
    case horizontal
    case grid
}
