// Created by Sébastien DAGUIN

import Foundation
import Testing

@testable import NoctisCLI

@Suite("CLI verified updates", .timeLimit(.minutes(1)))
struct CLIUpdateTests {
    @Test func failedChildCommandReportsActualDiagnostics() async throws {
        let runner = UpdateCommandRunner()
        do {
            _ = try await runner.run(
                URL(fileURLWithPath: "/bin/sh"),
                ["-c", "printf 'swift: simulated compiler error\\n' >&2; exit 42"],
                directory: FileManager.default.temporaryDirectory
            )
            Issue.record("The failing command unexpectedly succeeded")
        } catch let error as UpdateFailure {
            #expect(error.message.contains("status 42"))
            #expect(error.message.contains("simulated compiler error"))
        }
    }

    @Test func semanticVersionOrderingAndValidation() throws {
        let ordered = [
            "0.1.0", "0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.2", "0.2.0-alpha.10",
            "0.2.0-beta", "0.2.0-rc.1", "0.2.0", "0.10.0", "1.0.0", "10.0.0"
        ]
        let versions = try ordered.map { try #require(SemanticVersion($0)) }
        #expect(versions.sorted() == versions)
        #expect(SemanticVersion("v1.2.3+build.1") == SemanticVersion("1.2.3+other"))
        for invalid in [
            "1.2", "01.2.3", "1.2.03", "1.2.3-01", "1.2.3-", "1.2.3+", "1.2.3+a..b",
            "main", "1.2.3\n", "1.2.3.4", "1.2.3/a", "1.2.3+é", "-1.2.3"
        ] {
            #expect(SemanticVersion(invalid) == nil)
        }
        #expect(
            CLIUpdateService.stableTags(["v1.0.0-rc.1", "0.2.0", "0.10.0", "main", "v1.0.0"])
                == ["v1.0.0", "0.10.0", "0.2.0"])
    }

    @Test func detectsUpdatesAndNeverDowngrades() throws {
        #expect(try CLIUpdateService.needsUpdate(installed: "0.2.0", latest: "v0.10.0"))
        #expect(try CLIUpdateService.needsUpdate(installed: "0.2.0-dev", latest: "0.2.0"))
        #expect(try !CLIUpdateService.needsUpdate(installed: "1.0.0", latest: "v1.0.0"))
        #expect(try !CLIUpdateService.needsUpdate(installed: "2.0.0", latest: "1.0.0"))
        #expect(throws: UpdateFailure.self) {
            try CLIUpdateService.needsUpdate(installed: "unknown", latest: "1.0.0")
        }
    }

    @Test func parsesOnlyExplicitMaintenanceOptions() throws {
        for (flag, mode) in [
            ("--check", CLIUpdateMode.check), ("--dev", .development), ("--rollback", .rollback)
        ] {
            #expect(try NoctisCLI.command(arguments: ["update", flag]) == .updateMode(mode))
        }
        for arguments in [["update", "--yes"], ["update", "--dev", "--check"], ["--update"]] {
            #expect(throws: (any Error).self) { try NoctisCLI.command(arguments: arguments) }
        }
    }

    @Test func discoversTagsWithoutLexicographicOrPrereleaseMistakes() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let transport = FixtureUpdateTransport(responses: [
            Data(#"[{"name":"0.2.0"},{"name":"v0.10.0"},{"name":"1.0.0-rc.1"}]"#.utf8),
            Data(
                #"{"tag_name":"v0.10.0","draft":false,"prerelease":false,"body":"Changes","assets":[]}"#.utf8)
        ])
        let release = try await CLIUpdateService(transport: transport).latestRelease(in: fixture.base)
        #expect(release.tagName == "v0.10.0")
        let urls = await transport.urls
        #expect(urls.last?.path.hasSuffix("/releases/tags/v0.10.0") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).sorted() == ["prefix"])
    }

    @Test func invalidResponsesOfflineAndInterruptedDownloadsFailClosed() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        for response in [Data("not json".utf8), Data("{}".utf8), Data("[]".utf8)] {
            await #expect(throws: (any Error).self) {
                try await CLIUpdateService(transport: FixtureUpdateTransport(responses: [response]))
                    .latestRelease(in: fixture.base)
            }
        }
        for interrupted in [false, true] {
            let transport = FixtureUpdateTransport(responses: [], interrupted: interrupted)
            await #expect(throws: (any Error).self) {
                try await CLIUpdateService(transport: transport).latestRelease(in: fixture.base)
            }
            #expect(try fixture.active() == "versions/build-old")
        }
    }

    @Test func rejectsWrongArchitectureSourcesAndDangerousArchives() throws {
        #expect(try CLIUpdateService.artifactName(majorOS: 15) == "noctis-macos-arm64.tar")
        #expect(throws: UpdateFailure.self) { try CLIUpdateService.artifactName(architecture: "x86_64") }
        #expect(throws: UpdateFailure.self) { try CLIUpdateService.artifactName(majorOS: 14) }
        for url in [
            "http://github.com/a", "https://github.com.evil.test/a", "https://user@github.com/a",
            "https://localhost/a", "file:///tmp/a"
        ] {
            #expect(!UpdateRedirectPolicy.allows(URL(string: url)!))
        }
        try CLIUpdateService.validateArchive(
            list: "./\n./NoctisCLI\n", verbose: "drwxr-xr-x .\n-rwx------ NoctisCLI\n")
        for (list, verbose) in [
            ("../outside\n", "-rw------- outside\n"), ("/tmp/outside\n", "-rw------- outside\n"),
            ("NoctisCLI\n", "lrwxrwxrwx link\n"), ("NoctisCLI\n", "hrwxrwxrwx hardlink\n"),
            ("a\na\n", "-rw a\n-rw a\n"), ("a\n", ""), ("a\tfile\n", "-rw a\n")
        ] {
            #expect(throws: UpdateFailure.self) {
                try CLIUpdateService.validateArchive(list: list, verbose: verbose)
            }
        }
        let bad = CLIRelease(
            tagName: "1.0.0", draft: false, prerelease: false, body: nil,
            assets: [
                .init(
                    name: "noctis-macos-arm64.tar",
                    browserDownloadURL: URL(string: "https://evil.test/binary")!)
            ])
        #expect(throws: UpdateFailure.self) { try bad.artifact(named: "noctis-macos-arm64.tar") }
        #expect(throws: UpdateFailure.self) { try bad.artifact(named: "missing") }
    }

    @Test func checksumAndProvenanceAreBothRequiredBeforeExtraction() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let archive = Data("archive bytes".utf8)
        let path = fixture.base.appendingPathComponent("archive")
        try archive.write(to: path)
        let digest = try ManagedCLIInstallation.digest(path)
        let name = "noctis-macos-arm64.tar"
        let release = CLIRelease(
            tagName: "1.0.0", draft: false, prerelease: false, body: nil,
            assets: [name, name + ".sha256"].map {
                .init(
                    name: $0,
                    browserDownloadURL:
                        URL(
                            string:
                                "https://github.com/\(CLIUpdateService.repository)/releases/download/1.0.0/\($0)"
                        )!)
            })
        for validChecksum in [false, true] {
            let temporary = fixture.base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let checksum = "\(validChecksum ? digest : String(repeating: "0", count: 64))  \(name)\n"
            let runner = FixtureUpdateRunner(failAttestation: true)
            let service = CLIUpdateService(
                transport: FixtureUpdateTransport(responses: [archive, Data(checksum.utf8)]), runner: runner)
            await #expect(throws: UpdateFailure.self) {
                try await service.fetchVerified(
                    release, in: temporary, githubCLI: URL(fileURLWithPath: "/trusted/gh"))
            }
            let calls = await runner.calls
            #expect(calls.count == (validChecksum ? 1 : 0))
            if let call = calls.first {
                #expect(call.contains("--deny-self-hosted-runners"))
                #expect(call.contains("refs/tags/1.0.0"))
                #expect(call.contains("\(CLIUpdateService.repository)/.github/workflows/release-cli.yml"))
            }
            #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("payload").path))
        }
    }

    @Test func installationAndRollbackAreAtomicAndPreservePersonalData() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let personal = fixture.prefix.appendingPathComponent("models-and-preferences")
        try Data("preserved".utf8).write(to: personal)
        let runner = FixtureUpdateRunner()
        let installation = try fixture.installation(runner)
        let payload = try fixture.payload()
        try await installation.install(payload, expectedVersion: "1.0.0")
        let current = try fixture.active()
        #expect(current != "versions/build-old")
        #expect(try fixture.previous() == "versions/build-old")
        let calls = await runner.calls
        #expect(calls.count == 4)
        #expect(calls[0].hasSuffix("--help"))
        #expect(calls[3].contains("/bin/noctis doctor"))
        try await fixture.installation(runner).install(nil)
        #expect(try fixture.active() == "versions/build-old")
        #expect(try fixture.previous() == current)
        #expect(try String(contentsOf: personal, encoding: .utf8) == "preserved")
    }

    @Test func failedPostActivationHealthCheckRestoresPreviousLink() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let runner = FixtureUpdateRunner(failActivation: true)
        await #expect(throws: UpdateFailure.self) {
            try await fixture.installation(runner).install(fixture.payload())
        }
        #expect(try fixture.active() == "versions/build-old")
        try ManagedCLIInstallation.verify(fixture.old)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".install-lock").path)
        )
    }

    @Test func corruptionMissingBackupLocksAndSymlinksAreRejected() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installation = try fixture.installation(FixtureUpdateRunner())
        await #expect(throws: UpdateFailure.self) { try await installation.install(nil) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".install-lock"), withIntermediateDirectories: false)
        await #expect(throws: UpdateFailure.self) { try await installation.install(fixture.payload()) }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".install-lock"))
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appendingPathComponent("previous").path,
            withDestinationPath: "../../outside")
        await #expect(throws: UpdateFailure.self) { try await installation.install(nil) }
        let payload = try fixture.payload()
        try FileManager.default.createSymbolicLink(
            at: payload.appendingPathComponent("escape"),
            withDestinationURL: fixture.base)
        await #expect(throws: UpdateFailure.self) { try await installation.install(payload) }
        try Data("corrupted".utf8).write(to: fixture.old.appendingPathComponent("NoctisCLI"))
        #expect(throws: UpdateFailure.self) { try ManagedCLIInstallation.verify(fixture.old) }
        #expect(throws: UpdateFailure.self) {
            try ManagedCLIInstallation(
                prefix: fixture.prefix, executable: fixture.base.appendingPathComponent("unrelated"))
        }
        #expect(try fixture.active() == "versions/build-old")
    }
}

extension CLIUpdateTests {
    @Test func systemPathAliasesAreAcceptedButUserSymlinkPrefixesAreDenied() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let command = fixture.prefix.appendingPathComponent("bin/noctis")
        try FileManager.default.removeItem(at: command)
        let canonical = fixture.root.resolvingSymlinksInPath().path
        let alias = canonical.hasPrefix("/private/") ? String(canonical.dropFirst(8)) : "/private" + canonical
        try FileManager.default.createSymbolicLink(atPath: command.path,
                                                   withDestinationPath: alias + "/current/NoctisCLI")
        _ = try fixture.installation(FixtureUpdateRunner())
        let unsafe = fixture.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: fixture.prefix)
        #expect(throws: UpdateFailure.self) {
            try ManagedCLIInstallation(prefix: unsafe, executable: fixture.old.appendingPathComponent("NoctisCLI"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.base.path)
        #expect(throws: UpdateFailure.self) { try fixture.installation(FixtureUpdateRunner()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.base.path)
    }

    @Test func developmentUsesExactIsolatedRevisionAndRequiresConfirmation() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let products = fixture.base.appendingPathComponent("source/.build/release")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try Data("source build fixture".utf8).write(to: products.appendingPathComponent("NoctisCLI"))
        let runner = FixtureDevelopmentRunner(products: products)
        let transport = FixtureUpdateTransport(responses: [Data(#"[{"name":"0.2.0"}]"#.utf8)])
        let service = CLIUpdateService(transport: transport, runner: runner)
        await #expect(throws: UpdateFailure.self) {
            try await NoctisCLI.developmentPayload(service: service, temporary: fixture.base,
                                                   interactive: false, readConfirmation: { "yes" })
        }
        #expect(await runner.calls.isEmpty)
        await #expect(throws: UpdateFailure.self) {
            try await NoctisCLI.developmentPayload(service: service, temporary: fixture.base,
                                                   interactive: true, readConfirmation: { "no" })
        }
        #expect(await !runner.calls.contains { $0.contains("swift build") })
        let payload = try await NoctisCLI.developmentPayload(service: service, temporary: fixture.base,
                                                             interactive: true, readConfirmation: { "yes" })
        let identity = try JSONDecoder().decode(CLIBuildIdentity.self,
                                                from: Data(contentsOf: payload.appendingPathComponent("version.json")))
        #expect(identity.channel == "main")
        #expect(identity.commit == String(repeating: "a", count: 40))
        let calls = await runner.calls
        #expect(calls.contains { $0.contains("checkout --detach " + identity.commit) })
        #expect(calls.contains { $0.contains("refs/heads/main") })
        #expect(!calls.contains { $0.contains("scripts/") || $0.contains(" pull") || $0.contains(" reset") })
        #expect(try fixture.active() == "versions/build-old")
    }

    @Test func realArchiveExtractionAndActivationWithMockedPublisher() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let payload = try fixture.payload()
        let identity = CLIBuildIdentity(version: "1.0.0", channel: "stable", commit: String(repeating: "a", count: 40))
        let script = """
            #!/bin/sh
            # Created by Sébastien DAGUIN
            case "$1" in
              --version) echo '\(identity.display)' ;;
              --help|doctor) exit 0 ;;
              *) exit 1 ;;
            esac
            """
        try Data(script.utf8).write(to: payload.appendingPathComponent("NoctisCLI"))
        try JSONEncoder().encode(identity).write(to: payload.appendingPathComponent("version.json"))
        let runner = UpdateCommandRunner()
        let name = "noctis-macos-arm64.tar"
        let archive = fixture.base.appendingPathComponent("source.tar")
        _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                 ["-cf", archive.path, "-C", payload.path, "."], directory: fixture.base)
        let checksum = "\(try ManagedCLIInstallation.digest(archive))  \(name)\n"
        let release = CLIRelease(tagName: "1.0.0", draft: false, prerelease: false, body: nil,
                                 assets: [name, name + ".sha256"].map { .init(name: $0, browserDownloadURL:
            URL(string: "https://github.com/\(CLIUpdateService.repository)/releases/download/1.0.0/\($0)")!) })
        let transport = FixtureUpdateTransport(responses: [try Data(contentsOf: archive), Data(checksum.utf8)])
        let service = CLIUpdateService(transport: transport, runner: FixtureArchiveRunner())
        let verified = try await service.fetchVerified(release, in: fixture.base,
                                                       githubCLI: URL(fileURLWithPath: "/test/gh"))
        try await fixture.installation(runner).install(verified, expectedVersion: "1.0.0")
        #expect(try fixture.active() != "versions/build-old")
        #expect(try fixture.previous() == "versions/build-old")
        try ManagedCLIInstallation.verify(fixture.root.appendingPathComponent(try fixture.active()))
    }

    @Test func rollbackCanRecoverCorruptedCurrentFiles() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let runner = FixtureUpdateRunner()
        try await fixture.installation(runner).install(fixture.payload())
        let corrupted = fixture.root.appendingPathComponent(try fixture.active())
        try Data("broken resource".utf8).write(to: corrupted.appendingPathComponent("broken"))
        try await fixture.installation(runner).install(nil)
        #expect(try fixture.active() == "versions/build-old")
        #expect(try fixture.previous() == "versions/build-old")
    }

    @Test func maintenanceBinaryRunsWithoutModelOrMutableVersionSidecar() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidate = Bundle(for: CLIUpdateBundleAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("NoctisCLI")
        let binary = FileManager.default.isExecutableFile(atPath: candidate.path)
            ? candidate : project.appendingPathComponent(".build/debug/NoctisCLI")
        let runner = UpdateCommandRunner()
        let help = try await runner.run(binary, ["--help"], directory: URL(fileURLWithPath: "/"))
        let version = try await runner.run(binary, ["--version"], directory: URL(fileURLWithPath: "/"))
        #expect(help.contains("update --rollback"))
        #expect(help.contains("update --check"))
        #expect(version.hasPrefix("Noctis unknown (local)"))
    }
}

private final class CLIUpdateBundleAnchor: NSObject {}
