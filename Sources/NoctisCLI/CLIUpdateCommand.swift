// Created by Sébastien DAGUIN

import Darwin
import Foundation
import Noctis

enum CLIUpdateMode: String, Equatable {
    case stable, check, development, rollback
}

extension NoctisCLI {
    static func update(_ mode: CLIUpdateMode) async throws {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "noctis-update-\(UUID())")
        try files.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let progress = CLIUpdateProgress()
        let service = CLIUpdateService(
            transport: GitHubUpdateTransport(progress: progress),
            runner: ProgressUpdateRunner(base: UpdateCommandRunner(), progress: progress),
            progress: progress)
        if mode == .check || mode == .stable {
            guard try await installStable(mode, service: service, progress: progress, temporary: temporary) else {
                return
            }
        } else if mode == .rollback {
            try await progress.step("Restauration et diagnostic") {
                try await managedInstallation().install(nil)
            }
        } else {
            let installation = try managedInstallation()
            let payload = try await developmentPayload(service: service, temporary: temporary)
            try await progress.step("Installation · aide, version et diagnostic") {
                try await installation.install(payload)
            }
        }
        print(updateText("Contrôles locaux réussis : aide CLI · version · doctor · intégrité"))
        print(updateText("Suite de tests complète : non exécutée par la mise à jour."))
        print(
            updateText(
                "Installation verified. The previous version is available with noctis update --rollback."))
    }

    private static func installStable(_ mode: CLIUpdateMode, service: CLIUpdateService,
                                      progress: CLIUpdateProgress, temporary: URL) async throws -> Bool {
        let identity = CLIBuildIdentity.installed
        print(identity.display)
        let release = try await progress.step("Recherche de mise à jour") {
            try await service.latestRelease(in: temporary)
        }
        print(updateText("Latest stable version:") + " \(release.tagName)")
        print("https://github.com/\(CLIUpdateService.repository)/releases/tag/\(release.tagName)")
        if let notes = release.body {
            print(updateText("Modifications annoncées :"))
            for line in CLIUpdateProgress.summary(notes) { print("  • \(line)") }
        }
        let available = try CLIUpdateService.needsUpdate(
            installed: identity.version, latest: release.tagName)
        if !available {
            print(updateText("Noctis is already up to date:") + " \(identity.version)")
            return false
        }
        print(updateText("An update is available."))
        if mode == .check { return false }
        let installation = try managedInstallation()
        let payload = try await service.fetchVerified(release, in: temporary, githubCLI: try githubCLI())
        try await progress.step("Installation · aide, version et diagnostic") {
            try await installation.install(
                payload, expectedVersion: String(release.tagName.drop(while: { $0 == "v" })))
        }
        return true
    }

    private static func managedInstallation() throws -> ManagedCLIInstallation {
        let prefix =
            ProcessInfo.processInfo.environment["NOCTIS_PREFIX"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local").path
        guard prefix.hasPrefix("/") else { throw UpdateFailure("Unsafe installation path.") }
        return try ManagedCLIInstallation(
            prefix: URL(fileURLWithPath: prefix),
            executable: executableDirectory.appendingPathComponent("NoctisCLI"))
    }

    private static func githubCLI() throws -> URL {
        // Restrict the verifier to standard installation locations, never a repository-local PATH entry.
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw UpdateFailure(
            """
            GitHub CLI (gh) is required in /opt/homebrew/bin or /usr/local/bin to verify \
            provenance. Install it and authenticate with gh auth login.
            """
        )
    }

    static func developmentPayload(service: CLIUpdateService, temporary: URL,
                                   interactive: Bool = isatty(STDIN_FILENO) != 0,
                                   readConfirmation: () -> String? = { readLine() }) async throws -> URL {
        guard interactive else {
            throw UpdateFailure(
                "Development updates require an interactive terminal and explicit confirmation.")
        }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let runner = service.runner
        try await checkDevelopmentToolchain(runner: runner, temporary: temporary)
        let source = temporary.appendingPathComponent("source")
        _ = try await runner.run(
            git, ["-c", "core.hooksPath=/dev/null", "init", source.path], directory: temporary)
        _ = try await runner.run(
            git,
            [
                "-C", source.path, "-c", "core.hooksPath=/dev/null", "fetch", "--depth=20",
                "https://github.com/\(CLIUpdateService.repository).git", "refs/heads/main"
            ], directory: temporary)
        let revision = try await runner.run(
            git, ["-C", source.path, "rev-parse", "FETCH_HEAD^{commit}"], directory: temporary
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision.count == 40, revision.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateFailure("Invalid GitHub response or download.")
        }
        print(
            updateText(
                "Development only: main is not a stable release. Building may execute Swift package plugins.")
        )
        print("https://github.com/\(CLIUpdateService.repository)/commit/\(revision)")
        print(updateText("Type yes to build and install this exact revision:"))
        guard readConfirmation() == "yes" else {
            throw UpdateFailure("Update cancelled; the installation is unchanged.")
        }
        _ = try await runner.run(
            git, ["-C", source.path, "-c", "core.hooksPath=/dev/null", "checkout", "--detach", revision],
            directory: temporary)
        let recent = try await runner.run(
            git, ["-C", source.path, "log", "-4", "--format=%h %s", revision], directory: temporary)
        print(updateText("Commits récents de main (historique disponible) :"))
        for line in CLIUpdateProgress.summary(recent) { print("  • \(line)") }
        let base = try await service.latestStableTag(in: temporary)
        let identity = CLIBuildIdentity(
            version: String(base.drop(while: { $0 == "v" }).split(separator: "+")[0]) + "-dev",
            channel: "main", commit: revision)
        return try await buildDevelopment(source: source, identity: identity, runner: runner, temporary: temporary)
    }

    private static func checkDevelopmentToolchain(runner: any UpdateCommandRunning, temporary: URL) async throws {
        let swiftVersion = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift", "--version"], directory: temporary)
        guard let token = swiftVersion.components(separatedBy: "Swift version ").last?.split(separator: " ").first,
              let version = SemanticVersion(String(token)), version >= SemanticVersion("6.4.0")! else {
            throw UpdateFailure("Swift 6.4 or later and the Xcode Metal compiler are required.")
        }
        _ = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/xcrun"), ["metal", "--version"], directory: temporary)
    }

    private static func buildDevelopment(source: URL, identity: CLIBuildIdentity,
                                         runner: any UpdateCommandRunning, temporary: URL) async throws -> URL {
        let metadata = temporary.appendingPathComponent("version.json")
        try JSONEncoder().encode(identity).write(to: metadata)
        // Use the installed updater's build recipe, never scripts from the fetched source.
        let swift = URL(fileURLWithPath: "/usr/bin/xcrun")
        let flags = [
            "swift", "build", "--package-path", source.path, "-c", "release", "--product", "NoctisCLI",
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__noctis", "-Xlinker",
            metadata.path
        ]
        _ = try await runner.run(swift, flags, directory: temporary)
        let productsPath = try await runner.run(
            swift,
            [
                "swift", "build", "--package-path", source.path,
                "-c", "release", "--show-bin-path"
            ], directory: temporary
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let products = URL(fileURLWithPath: productsPath).standardizedFileURL
        guard products.path.hasPrefix(source.path + "/.build/") else {
            throw UpdateFailure("Unsafe installation path.")
        }
        let payload = temporary.appendingPathComponent("payload")
        try FileManager.default.createDirectory(
            at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(
            at: products.appendingPathComponent("NoctisCLI"), to: payload.appendingPathComponent("NoctisCLI"))
        for resource in try FileManager.default.contentsOfDirectory(
            at: products, includingPropertiesForKeys: nil)
        where ["bundle", "dylib", "metallib"].contains(resource.pathExtension) {
            try FileManager.default.copyItem(
                at: resource, to: payload.appendingPathComponent(resource.lastPathComponent))
        }
        try FileManager.default.copyItem(at: metadata, to: payload.appendingPathComponent("version.json"))
        try ManagedCLIInstallation.validateTree(payload)
        let reported = try await runner.run(payload.appendingPathComponent("NoctisCLI"), ["--version"],
                                             directory: temporary)
        guard reported.trimmingCharacters(in: .whitespacesAndNewlines) == identity.display else {
            throw UpdateFailure("The artifact version does not match the requested release.")
        }
        return payload
    }
}
