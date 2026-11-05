//
//  File.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 04/11/2026.
//

import Foundation

enum WorkspaceError: Error, LocalizedError, Equatable {
    case invalidDirectory
    case invalidPath
    case outsideWorkspace
}
