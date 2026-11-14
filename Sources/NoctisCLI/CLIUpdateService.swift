// Created by Sébastien DAGUIN

import CryptoKit
import Foundation

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { updateText(message) }
}

struct UpdateHTTPFailure: LocalizedError {
    let status: Int
    var errorDescription: String? {
        updateText(status == 403 || status == 429 ? "GitHub rate limit reached. Try again later." :
            "GitHub request failed. The installation is unchanged.")
    }
}

func updateText(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: "Localizable")
}

protocol UpdateTransport: Sendable {
    func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws
}

final class UpdateRedirectPolicy: NSObject, URLSessionDownloadDelegate {
    let maximumSize: Int64
    init(maximumSize: Int64) { self.maximumSize = maximumSize }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize { downloadTask.cancel() }
    }

    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && [
                "api.github.com", "github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com"
            ]
            .contains(url.host ?? "")
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

struct GitHubUpdateTransport: UpdateTransport {
    func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws {
        guard UpdateRedirectPolicy.allows(url) else { throw UpdateFailure("Invalid download source.") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: UpdateRedirectPolicy(maximumSize: maximumSize),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("NoctisCLI-updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse else {
                throw UpdateFailure("Invalid GitHub response or download.")
            }
            guard response.statusCode == 200 else { throw UpdateHTTPFailure(status: response.statusCode) }
            guard
                let finalURL = response.url, UpdateRedirectPolicy.allows(finalURL),
                let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size > 0, size <= maximumSize
            else { throw UpdateFailure("Invalid GitHub response or download.") }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch is CancellationError { throw CancellationError() } catch let error as UpdateHTTPFailure {
            throw error
        } catch let error as UpdateFailure { throw error } catch {
            throw UpdateFailure(
                "Download failed. Check your connection and try again; the installation is unchanged.")
        }
    }
}

protocol UpdateCommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], directory: URL?) async throws -> String
}

private final class UpdateChild: @unchecked Sendable {
    let process = Process()
    let lock = NSLock()
    var cancelled = false

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

struct UpdateCommandRunner: UpdateCommandRunning {
    func run(_ executable: URL, _ arguments: [String], directory: URL? = nil) async throws -> String {
        let child = UpdateChild()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctis-process-\(UUID())")
        let created = FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600])
        guard created else {
            throw UpdateFailure("Cannot create a private temporary file.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        child.process.executableURL = executable
        child.process.arguments = arguments
        child.process.currentDirectoryURL = directory
        child.process.standardOutput = output
        child.process.standardError = output
        child.process.standardInput = FileHandle.nullDevice
        // Ignore Git rewrites/hooks and dynamic-loader overrides inherited from the caller.
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("GIT_") && !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("LD_")
        }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_HOST"] = "github.com"
        child.process.environment = environment
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                child.process.terminationHandler = { process in
                    let code = process.terminationStatus
                    continuation.resume(returning: process.terminationReason == .exit ? code : -code)
                }
                do { try child.start() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            child.cancel()
        }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 8 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else {
            throw UpdateFailure("Invalid command output (over 8 MiB or invalid UTF-8).")
        }
        guard status == 0 else {
            // Retain only bounded command output; no private log file survives the operation.
            let diagnostics = String(text.suffix(4_096))
            throw UpdateFailure(
                "Command exited with status \(status).\n" +
                (diagnostics.isEmpty ? "No diagnostic output was produced." : diagnostics)
            )
        }
        return text
    }
}

struct CLIReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct CLIRelease: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [CLIReleaseAsset]
    enum CodingKeys: String, CodingKey {
        case draft, prerelease, body, assets
        case tagName = "tag_name"
    }

    func artifact(named name: String) throws -> CLIReleaseAsset {
        let matches = assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first,
            asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host == "github.com",
            asset.browserDownloadURL.path
                == "/\(CLIUpdateService.repository)/releases/download/\(tagName)/\(name)",
            asset.browserDownloadURL.query == nil, asset.browserDownloadURL.fragment == nil,
            UpdateRedirectPolicy.allows(asset.browserDownloadURL)
        else {
            throw UpdateFailure(
                "This release has no compatible verified artifact. Use --check or wait for a signed release.")
        }
        return asset
    }
}

struct CLIUpdateService: Sendable {
    static let repository = "Sebastien972-collab/NoctisAi"
    let transport: any UpdateTransport
    let runner: any UpdateCommandRunning

    init(
        transport: any UpdateTransport = GitHubUpdateTransport(),
        runner: any UpdateCommandRunning = UpdateCommandRunner()
    ) {
        self.transport = transport
        self.runner = runner
    }

    static func stableTags(_ tags: [String]) -> [String] {
        tags.filter { SemanticVersion($0)?.prerelease.isEmpty == true }.sorted {
            let left = SemanticVersion($0)!
            let right = SemanticVersion($1)!
            return left == right ? $0 < $1 : left > right
        }
    }

    static func needsUpdate(installed: String, latest: String) throws -> Bool {
        guard let current = SemanticVersion(installed), let remote = SemanticVersion(latest) else {
            throw UpdateFailure(
                "The installed version is unknown. Reinstall from a trusted checkout to enable updates.")
        }
        return current < remote
    }

    func latestStableTag(in temporary: URL) async throws -> String {
        struct Tag: Decodable { let name: String }
        var tags: [String] = []
        // Tags are not ordered by SemVer. Read all pages and fail rather than silently truncate.
        for page in 1...100 {
            let url = URL(
                string: "https://api.github.com/repos/\(Self.repository)/tags?per_page=100&page=\(page)")!
            let batch: [Tag] = try await json(url, in: temporary)
            tags += batch.map(\.name)
            if batch.count < 100 { break }
            if page == 100 {
                throw UpdateFailure("Too many tags; cannot determine the latest stable version safely.")
            }
        }
        guard let tag = Self.stableTags(tags).first else {
            throw UpdateFailure("No stable version is published.")
        }
        return tag
    }

    func latestRelease(in temporary: URL) async throws -> CLIRelease {
        let tag = try await latestStableTag(in: temporary)
        let release: CLIRelease
        do {
            release = try await json(
                URL(string: "https://api.github.com/repos/\(Self.repository)/releases/tags/\(tag)")!,
                in: temporary)
        } catch let error as UpdateHTTPFailure where error.status == 404 {
            return CLIRelease(
                tagName: tag, draft: false, prerelease: false,
                body: updateText("The latest stable tag has no published stable release."), assets: [])
        }
        guard release.tagName == tag, !release.draft, !release.prerelease else {
            throw UpdateFailure("The latest stable tag has no published stable release.")
        }
        return release
    }

    private func json<Value: Decodable>(_ url: URL, in temporary: URL) async throws -> Value {
        let path = temporary.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try await transport.download(url, to: path, maximumSize: 5 * 1024 * 1024)
        do { return try JSONDecoder().decode(Value.self, from: Data(contentsOf: path)) } catch {
            throw UpdateFailure("Invalid GitHub response or download.")
        }
    }

    static func artifactName(
        architecture: String = "arm64",
        majorOS: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )
        throws -> String {
        guard architecture == "arm64", majorOS >= 15 else {
            throw UpdateFailure("macOS 15 or later on Apple Silicon is required.")
        }
        return "noctis-macos-arm64.tar"
    }

    func fetchVerified(_ release: CLIRelease, in temporary: URL, githubCLI: URL) async throws -> URL {
        #if arch(arm64)
            let name = try Self.artifactName()
        #else
            let name = try Self.artifactName(architecture: "unsupported")
        #endif
        let archive = temporary.appendingPathComponent(name)
        let checksum = temporary.appendingPathComponent("\(name).sha256")
        try await transport.download(
            release.artifact(named: name).browserDownloadURL,
            to: archive, maximumSize: 512 * 1024 * 1024)
        try await transport.download(
            release.artifact(named: "\(name).sha256").browserDownloadURL,
            to: checksum, maximumSize: 1024)
        let expected = try String(contentsOf: checksum, encoding: .utf8).split(whereSeparator: \.isWhitespace)
        guard expected.count == 2, expected[1] == name, expected[0].count == 64,
            expected[0].allSatisfy({ $0.isHexDigit }),
            try ManagedCLIInstallation.digest(archive) == expected[0].lowercased()
        else {
            throw UpdateFailure("Integrity verification failed. Nothing was installed.")
        }
        // Sigstore verification binds bytes to the official workflow AND exact tag, not just a checksum.
        do {
            _ = try await runner.run(
                githubCLI,
                [
                    "attestation", "verify", archive.path,
                    "--repo", Self.repository, "--hostname", "github.com", "--signer-workflow",
                    "\(Self.repository)/.github/workflows/release-cli.yml", "--source-ref",
                    "refs/tags/\(release.tagName)",
                    "--deny-self-hosted-runners"
                ], directory: temporary)
        } catch is CancellationError { throw CancellationError() } catch {
            throw UpdateFailure("Provenance verification failed. Check GitHub CLI version and authentication.")
        }
        return try await extractVerifiedArchive(archive, release: release, temporary: temporary)
    }

    private func extractVerifiedArchive(_ archive: URL, release: CLIRelease, temporary: URL) async throws -> URL {
        let list = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path], directory: temporary)
        let verbose = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-tvf", archive.path], directory: temporary)
        try Self.validateArchive(list: list, verbose: verbose)
        let extracted = temporary.appendingPathComponent("payload")
        try FileManager.default.createDirectory(
            at: extracted, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        _ = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xf", archive.path, "-C", extracted.path, "--no-same-owner", "--no-same-permissions"],
            directory: temporary)
        try ManagedCLIInstallation.validateTree(extracted)
        let identity = try JSONDecoder().decode(
            CLIBuildIdentity.self,
            from: Data(contentsOf: extracted.appendingPathComponent("version.json")))
        guard identity.version == String(release.tagName.drop(while: { $0 == "v" })),
            identity.channel == "stable",
            identity.commit.count == 40, identity.commit.allSatisfy({ $0.isHexDigit })
        else {
            throw UpdateFailure("The artifact version does not match the requested release.")
        }
        let reported = try await runner.run(extracted.appendingPathComponent("NoctisCLI"), ["--version"],
                                             directory: temporary)
        guard reported.trimmingCharacters(in: .whitespacesAndNewlines) == identity.display else {
            throw UpdateFailure("The artifact version does not match the requested release.")
        }
        return extracted
    }

    static func validateArchive(list: String, verbose: String) throws {
        let names = list.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        let records = verbose.split(separator: "\n")
        let normalized = names.map { $0.split(separator: "/").filter { $0 != "." }.joined(separator: "/") }
        guard !names.isEmpty, names.count <= 20_000, records.count == names.count,
            Set(normalized).count == names.count,
            names.allSatisfy({ name in
                let components = name.split(separator: "/")
                return !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\r")
                    && !name.contains("\t") && components.allSatisfy { $0 != ".." }
                    && name.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
            }), records.allSatisfy({ $0.first == "-" || $0.first == "d" })
        else {
            throw UpdateFailure("Unsafe or malformed archive. Nothing was installed.")
        }
    }
}
