//
//  LocalWorkspace.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 04/11/2026.
//

import Foundation

struct LocalWorkSpace {
    let rootUrl: URL

    init(rootUrl: URL) throws {

        guard rootUrl.isFileURL else {
            throw WorkspaceError.invalidDirectory
        }

        let directoryUrl =  rootUrl
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: directoryUrl.path()
            , isDirectory: &isDirectory),
              isDirectory.boolValue else {

            throw WorkspaceError.invalidDirectory
        }

        self.rootUrl = directoryUrl

    }

    func resolve(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.contains("\0"),
              !(relativePath as NSString).isAbsolutePath else {
            throw WorkspaceError.invalidPath
        }

        let resolvedURL = rootUrl
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootComponents = rootUrl.pathComponents
        let resolvedComponents = resolvedURL.pathComponents

        guard resolvedComponents.starts(with: rootComponents) else {
            throw WorkspaceError.outsideWorkspace
        }

        return resolvedURL
    }
}
