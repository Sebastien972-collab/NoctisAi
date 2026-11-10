// Created by Sébastien DAGUIN

import Foundation
import Darwin

/// Pins the authorized directory inode. All descendants are opened relative to held descriptors.
public final class AuthorizedWorkspace: @unchecked Sendable {
    private let root: Int32
    private static let ignored = Set([".git", ".build", "node_modules", ".DS_Store"])

    public init(authorizing rootURL: URL) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"), !rootURL.path.contains("\0") else {
            throw AgentError.invalidPath
        }
        let components = rootURL.path.split(separator: "/").map(String.init)
        guard !components.contains("..") else { throw AgentError.invalidPath }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentError.accessDenied }
        do {
            for component in components where component != "." {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AgentError.accessDenied }
                close(descriptor)
                descriptor = next
            }
            root = descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(root) }

    private func openPath(_ path: String, directory: Bool) throws -> Int32 {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              path.utf8.count <= 4_096 else { throw AgentError.invalidPath }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(".."), components.count <= 64 else { throw AgentError.invalidPath }
        var descriptor = dup(root)
        guard descriptor >= 0 else { throw AgentError.ioFailure }
        do {
            let parts = components.filter { $0 != "." }
            for (index, part) in parts.enumerated() {
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    | ((directory || index < parts.count - 1) ? O_DIRECTORY : 0)
                let next = openat(descriptor, part, flags)
                guard next >= 0 else { throw AgentError.accessDenied }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private struct Entry: Encodable {
        let name: String
        let kind: String
    }

    private struct DirectoryListing {
        let items: [Entry]
        let truncated: Bool
        let scanned: Int
    }

    private func entries(_ descriptor: Int32, limit: Int) throws -> DirectoryListing {
        // A new open description avoids sharing a directory offset with dup(root).
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw AgentError.ioFailure }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw AgentError.ioFailure
        }
        defer { closedir(stream) }
        var items: [Entry] = []
        var visited = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let pointer = readdir(stream) else {
                guard errno == 0 else { throw AgentError.ioFailure }
                return .init(items: items.sorted { $0.name < $1.name }, truncated: false, scanned: visited)
            }
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            visited += 1
            if visited > limit {
                return .init(items: items.sorted { $0.name < $1.name }, truncated: true, scanned: visited)
            }
            guard !Self.ignored.contains(name) else { continue }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = metadata.st_mode & S_IFMT
            let kind = mode == S_IFDIR ? "directory" : (mode == S_IFREG ? "file" : "excluded")
            items.append(Entry(name: name, kind: kind))
        }
    }

    private func directoryEntries(path: String, limit: Int) throws -> DirectoryListing {
        let descriptor = try openPath(path, directory: true)
        defer { close(descriptor) }
        return try entries(descriptor, limit: limit)
    }

    func listFiles(path: String) throws -> String {
        let descriptor = try openPath(path, directory: true)
        defer { close(descriptor) }
        let result = try entries(descriptor, limit: 200)
        struct Listing: Encodable {
            let trust = "UNTRUSTED_WORKSPACE_DATA"
            let entries: [Entry]
            let truncated: Bool
        }
        return try ToolRegistry.json(Listing(entries: result.items, truncated: result.truncated))
    }

    private func text(path: String) throws -> String {
        let descriptor = try openPath(path, directory: false)
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw AgentError.ioFailure }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            throw AgentError.notRegularFile
        }
        guard metadata.st_size <= 65_536 else { throw AgentError.fileTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while data.count <= 65_536 {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, 65_537 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentError.ioFailure
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= 65_536 else { throw AgentError.fileTooLarge }
        guard let value = String(data: data, encoding: .utf8), !value.contains("\0") else {
            throw AgentError.invalidUTF8
        }
        return value
    }

    func readFile(path: String) throws -> String {
        try ToolRegistry.json(["trust": "UNTRUSTED_WORKSPACE_DATA", "content": text(path: path)])
    }

    private struct SearchMatch: Encodable { let path: String; let line: Int; let text: String }

    private func fileMatches(path: String, query: String) throws -> [SearchMatch] {
        let content = try text(path: path)
        var matches: [SearchMatch] = []
        for (index, line) in content.components(separatedBy: "\n").enumerated() where line.contains(query) {
            try Task.checkCancellation()
            let excerpt = String(String.UnicodeScalarView(line.unicodeScalars.prefix(128)))
            matches.append(.init(path: path, line: index + 1, text: excerpt))
            if matches.count == 50 { break }
        }
        return matches
    }

    func searchCode(path: String, query: String) throws -> String {
        struct Results: Encodable {
            let trust = "UNTRUSTED_WORKSPACE_DATA"
            let matches: [SearchMatch]
            let truncated: Bool
            let skippedFiles: Int
        }
        var pending = [(path, 0)]
        var matches: [SearchMatch] = []
        var visited = 0
        var files = 0
        var skipped = 0
        var truncated = false
        while !pending.isEmpty {
            try Task.checkCancellation()
            let (directory, depth) = pending.removeLast()
            let listing = try directoryEntries(path: directory, limit: min(200, 1_000 - visited))
            truncated = truncated || listing.truncated
            visited += listing.scanned
            for item in listing.items {
                try Task.checkCancellation()
                let relative = directory == "." ? item.name : directory + "/" + item.name
                if item.kind == "directory" {
                    if depth < 16 { pending.append((relative, depth + 1)) } else { truncated = true }
                } else if item.kind == "file" {
                    files += 1
                    if files > 64 { truncated = true; break }
                    do {
                        let found = try fileMatches(path: relative, query: query)
                        matches.append(contentsOf: found.prefix(50 - matches.count))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch { skipped += 1 }
                }
                if matches.count == 50 { break }
            }
            if visited >= 1_000 || files > 64 || matches.count == 50 { truncated = true; break }
        }
        return try ToolRegistry.json(Results(matches: matches, truncated: truncated, skippedFiles: skipped))
    }
}
