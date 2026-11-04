//
//  AIChatMessage.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 04/11/2026.
//

import Foundation

public struct AIChatMessage: Equatable, Sendable {
    public enum Role: Sendable { case user, assistant, system }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
