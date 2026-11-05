//
//  LocalWorkspaceTests.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 04/11/2026.
//


import Foundation
import Testing
@testable import Noctis

struct LocalWorkspaceTests {
    @Test
    func resolvesOnlyPathsInsideWorkspace() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        let rootURL = temporaryURL
            .appendingPathComponent("project")

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let workspace = try LocalWorkSpace(rootUrl: rootURL)

        let fileURL = try workspace.resolve(
            relativePath: "Sources/main.swift"
        )

        #expect(
            fileURL == workspace.rootUrl
                .appendingPathComponent("Sources/main.swift")
        )

        #expect(throws: WorkspaceError.invalidPath) {
            try workspace.resolve(relativePath: "/etc/passwd")
        }

        #expect(throws: WorkspaceError.outsideWorkspace) {
            try workspace.resolve(relativePath: "../outside.txt")
        }

        #expect(throws: WorkspaceError.outsideWorkspace) {
            try workspace.resolve(
                relativePath: "../project-secret/config.txt"
            )
        }
    }
    
    @Test
    func rejectsSymbolicLinkOutsideWorkspace() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        let rootURL = temporaryURL.appendingPathComponent("project")
        let outsideURL = temporaryURL.appendingPathComponent("outside.txt")

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        try Data("Contenu extérieur".utf8).write(to: outsideURL)

        let linkURL = rootURL.appendingPathComponent("link.txt")

        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outsideURL
        )

        let workspace = try LocalWorkSpace(rootUrl: rootURL)

        #expect(throws: WorkspaceError.outsideWorkspace) {
            try workspace.resolve(relativePath: "link.txt")
        }
    }
}
