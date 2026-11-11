// Created by Sébastien DAGUIN

import CryptoKit
import Darwin
import Foundation

struct ManagedCLIInstallation: Sendable {
    let prefix: URL
    let executable: URL
    let runner: any UpdateCommandRunning
    private var root: URL { prefix.appendingPathComponent("share/noctis") }
    private var versions: URL { root.appendingPathComponent("versions") }
    private var command: URL { prefix.appendingPathComponent("bin/noctis") }

    init(prefix: URL, executable: URL, runner: any UpdateCommandRunning = UpdateCommandRunner()) throws {
        self.prefix = prefix.standardizedFileURL
        self.executable = executable.standardizedFileURL
        self.runner = runner
        try validateLayout()
    }

    private func validateLayout() throws {
        try validateAncestors()
        guard prefix.path.hasPrefix("/"), prefix.path != "/",
            prefix.resolvingSymlinksInPath().path == prefix.path
        else { throw UpdateFailure("Unsafe installation path.") }
        for path in [
            prefix, prefix.appendingPathComponent("bin"), prefix.appendingPathComponent("share"), root,
            versions
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                let permissions = attributes[.posixPermissions] as? NSNumber,
                permissions.intValue & 0o022 == 0,
                path.resolvingSymlinksInPath().path == path.path
            else { throw UpdateFailure("Unsafe installation path.") }
        }
        let commandTarget = try FileManager.default.destinationOfSymbolicLink(atPath: command.path)
        guard commandTarget.hasPrefix("/"),
            URL(fileURLWithPath: commandTarget).standardizedFileURL.path
                == root.appendingPathComponent("current/NoctisCLI").path,
            command.resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path,
            try target("current").appendingPathComponent("NoctisCLI").path
                == executable.resolvingSymlinksInPath().path
        else {
            throw UpdateFailure(
                "This executable is not in an authorized Noctis installation. Reinstall with scripts/install.sh."
            )
        }
    }

    private func target(_ link: String) throws -> URL {
        guard let value = try? FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent(link).path) else {
            throw UpdateFailure("No previous working version is available.")
        }
        guard value.hasPrefix("versions/build-"), value.split(separator: "/").count == 2,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 47].contains($0)
            })
        else {
            throw UpdateFailure("Unsafe installation path.")
        }
        let path = root.appendingPathComponent(value)
        guard path.resolvingSymlinksInPath().path == path.path else { throw UpdateFailure("Unsafe installation path.") }
        return path
    }

    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateTree(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            directory.resolvingSymlinksInPath().path == directory.path
        else { throw UpdateFailure("Unsafe installation path.") }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        else {
            throw UpdateFailure("Unsafe installation path.")
        }
        var count = 0
        for case let path as URL in enumerator {
            count += 1
            let values = try path.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey
            ])
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard count <= 20_000, values.isSymbolicLink != true,
                values.isRegularFile == true || values.isDirectory == true,
                values.isRegularFile != true || (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                path.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/")
            else {
                throw UpdateFailure("Unsafe installation path.")
            }
        }
    }

    private static func inventory(_ directory: URL) throws -> [String: String] {
        try validateTree(directory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw UpdateFailure("Unsafe installation path.")
        }
        var result: [String: String] = [:]
        for case let path as URL in enumerator
        where try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let name = String(
                path.resolvingSymlinksInPath().path.dropFirst(
                    directory.resolvingSymlinksInPath().path.count + 1))
            if name != "integrity.json" { result[name] = try digest(path) }
        }
        guard result["NoctisCLI"] != nil else {
            throw UpdateFailure("The application executable is missing.")
        }
        return result
    }

    static func seal(_ directory: URL) throws {
        let manifest = directory.appendingPathComponent("integrity.json")
        guard !FileManager.default.fileExists(atPath: manifest.path) else {
            throw UpdateFailure("Unexpected integrity manifest in application payload.")
        }
        try JSONEncoder().encode(inventory(directory)).write(to: manifest, options: .atomic)
    }

    static func verify(_ directory: URL) throws {
        let actual = try inventory(directory)
        let manifest = directory.appendingPathComponent("integrity.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard
                let expected = try? JSONDecoder().decode(
                    [String: String].self, from: Data(contentsOf: manifest)),
                expected == actual
            else { throw UpdateFailure("Integrity verification failed. Nothing was installed.") }
        } else {
            // Compatibility with installations created by the original trusted source installer.
            let checksum = directory.appendingPathComponent("checksums.sha256")
            let text = try String(contentsOf: checksum, encoding: .utf8)
            var expected: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard line.count > 68, line.dropFirst(64).hasPrefix("  ./") else {
                    throw UpdateFailure("Integrity verification failed. Nothing was installed.")
                }
                let name = String(line.dropFirst(68))
                guard expected[name] == nil else {
                    throw UpdateFailure("Integrity verification failed. Nothing was installed.")
                }
                expected[name] = String(line.prefix(64))
            }
            guard expected == actual.filter({ $0.key != "checksums.sha256" }) else {
                throw UpdateFailure("Integrity verification failed. Nothing was installed.")
            }
        }
    }

    private func replaceLink(_ name: String, with directory: URL) throws {
        guard directory.deletingLastPathComponent().path == versions.path else {
            throw UpdateFailure("Unsafe installation path.")
        }
        let temporary = root.appendingPathComponent(".link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createSymbolicLink(
            atPath: temporary.path,
            withDestinationPath: "versions/\(directory.lastPathComponent)")
        guard rename(temporary.path, root.appendingPathComponent(name).path) == 0 else {
            throw UpdateFailure(
                "Cannot activate this version. Check installation permissions; no privilege elevation is attempted."
            )
        }
    }

    private func smokeTest(_ directory: URL, expectedVersion: String? = nil) async throws {
        let binary = directory.appendingPathComponent("NoctisCLI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw UpdateFailure("The application executable is missing.")
        }
        _ = try await runner.run(binary, ["--help"], directory: URL(fileURLWithPath: "/"))
        let version = try await runner.run(binary, ["--version"], directory: URL(fileURLWithPath: "/"))
        if let expectedVersion, !version.hasPrefix("Noctis \(expectedVersion) (") {
            throw UpdateFailure("The artifact version does not match the requested release.")
        }
        _ = try await runner.run(binary, ["doctor"], directory: URL(fileURLWithPath: "/"))
    }

    private func acquireLock() throws -> URL {
        let lock = root.appendingPathComponent(".install-lock")
        do {
            try FileManager.default.createDirectory(
                at: lock, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateFailure(
                "Installation locked. Another operation may be running; inspect .install-lock after an interruption."
            )
        }
        return lock
    }

    func install(_ payload: URL?, expectedVersion: String? = nil) async throws {
        try validateLayout()
        let lock = try acquireLock()
        defer { try? FileManager.default.removeItem(at: lock) }
        try validateLayout()
        let old = try target("current")
        let oldVerified: Bool
        do {
            try Self.verify(old)
            oldVerified = true
        } catch {
            if payload != nil { throw error }
            oldVerified = false
        }
        let prior = try? target("previous")
        let candidate: URL
        if let payload {
            try Self.validateTree(payload)
            candidate = versions.appendingPathComponent("build-\(UUID())")
            try FileManager.default.copyItem(at: payload, to: candidate)
            do { try Self.seal(candidate) } catch {
                try? FileManager.default.removeItem(at: candidate)
                throw error
            }
        } else {
            candidate = try target("previous")
        }
        // Keep every published version immutable and restrict app files to this user.
        var committed = false
        defer {
            if !committed, payload != nil, (try? target("current").path) != candidate.path {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        try Self.verify(candidate)
        try await smokeTest(candidate, expectedVersion: expectedVersion)
        try Task.checkCancellation()
        if oldVerified { try replaceLink("previous", with: old) }
        try await activate(candidate, replacing: old, prior: prior)
        committed = true
    }

    private func activate(_ candidate: URL, replacing old: URL, prior: URL?) async throws {
        do {
            try replaceLink("current", with: candidate)
            _ = try await runner.run(command, ["doctor"], directory: URL(fileURLWithPath: "/"))
            try Task.checkCancellation()
        } catch {
            // Restoration is synchronous and must run even when the async task has been cancelled.
            do {
                try replaceLink("current", with: old)
                if let prior { try replaceLink("previous", with: prior) }
            } catch {
                throw UpdateFailure(
                    """
                    Automatic restoration failed. The previous version is preserved under \
                    versions; restore the current link manually.
                    """
                )
            }
            throw error
        }
    }
}

private extension ManagedCLIInstallation {
    func validateAncestors() throws {
        var path = prefix.deletingLastPathComponent()
        while path.path != "/" {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            let type = attributes[.type] as? FileAttributeType
            // Sticky system temporary directories protect each user's entries. Other writable
            // ancestors could let another user replace the entire installation during activation.
            guard owner == 0 || owner == getuid(), mode & 0o022 == 0 || mode & 0o1000 != 0,
                  type == .typeDirectory || (owner == 0 && type == .typeSymbolicLink) else {
                throw UpdateFailure("Unsafe installation path.")
            }
            path.deleteLastPathComponent()
        }
    }
}
