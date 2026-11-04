//
//  AIModelLoadPhase.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 04/11/2026.
//

import Foundation

public enum AIModelLoadPhase: Equatable, Sendable {
    case downloading
    case loading
    case ready
}
