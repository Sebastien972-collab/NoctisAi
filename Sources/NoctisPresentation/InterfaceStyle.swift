// Created by Sébastien DAGUIN

import Foundation

/// Optional visual emphasis attached to a node. Independent of any renderer:
/// color tokens are validated against a small allowed set downstream.
public struct InterfaceStyle: Codable, Sendable, Equatable {
    public enum Emphasis: String, Codable, Sendable, Equatable {
        case normal
        case bold
        case dim
        case italic
    }

    public var emphasis: Emphasis?
    public var foreground: String?
    public var background: String?

    public init(emphasis: Emphasis? = nil, foreground: String? = nil, background: String? = nil) {
        self.emphasis = emphasis
        self.foreground = foreground
        self.background = background
    }
}
