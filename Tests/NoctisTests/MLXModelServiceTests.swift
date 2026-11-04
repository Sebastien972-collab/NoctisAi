//
//  MLXModelServiceTests.swift
//  NoctisTests
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import Testing
import HuggingFace
import Synchronization
@testable import Noctis

@Suite("Garde du moteur MLX sans chargement du modèle")
struct MLXModelServiceTests {
    @Test("Refuse la génération tant que le modèle n’est pas chargé",
          arguments: ["Bonjour", "", " \t\n "])
    func generateBeforeLoadingThrows(prompt: String) async throws {
        let service = MLXModelService()

        let error = await #expect(throws: MLXModelServiceError.self) {
            _ = try await service.generate(prompt: prompt)
        }

        let failure = try #require(error)
        #expect(failure.localizedDescription == "Le modèle Noctis n'est pas encore chargé.")
    }
}


private final class OfflineModelURLProtocol: URLProtocol {
    static let requests = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0[request.url!.host!, default: 0] += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@Suite("Installation locale du modèle", .timeLimit(.minutes(1)))
struct CachedModelDownloaderTests {
    @Test func installedSnapshotSurvivesOfflineRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        let repo: Repo.ID = "test/model"
        let revision = String(repeating: "a", count: 40)
        for (filename, contents) in [
            "config.json": "{}", "tokenizer_config.json": "{}", "tokenizer.json": "{}",
            "model.safetensors.index.json": "{\"weight_map\":{\"a\":\"model-1.safetensors\",\"b\":\"model-2.safetensors\"}}",
            "model-1.safetensors": "first", "model-2.safetensors": "second"
        ] {
            try await cache.storeData(Data(contents.utf8), repo: repo, kind: .model,
                                      revision: revision, filename: filename,
                                      etag: filename, ref: "main")
        }
        let host = UUID().uuidString.lowercased() + ".invalid"
        let phases = Mutex<[AIModelLoadPhase]>([])
        // Each pass creates a new client, as after an application restart.
        for _ in 0..<2 {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineModelURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let downloader = CachedModelDownloader(
                client: HubClient(session: session, host: URL(string: "https://" + host)!, cache: cache),
                phase: { phase in phases.withLock { $0.append(phase) } }
            )
            let directory = try await downloader.download(
                id: repo.description, revision: "main", matching: ["*.json", "*.jinja", "*.safetensors"],
                useLatest: false, progressHandler: { _ in }
            )
            #expect(CachedModelDownloader.isCompleteModel(at: directory))
        }
        #expect(OfflineModelURLProtocol.requests.withLock { $0[host, default: 0] } == 0)
        #expect(phases.withLock { $0 } == [.loading, .loading])
        let directory = try cache.snapshotPath(repo: repo, kind: .model, commitHash: revision)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("model-2.safetensors"))
        #expect(!CachedModelDownloader.isCompleteModel(at: directory))
    }

    @Test func quantizedShardsCanReplaceAStaleOriginalIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["config.json": "{}", "tokenizer_config.json": "{}", "tokenizer.json": "{}",
                     "model.safetensors.index.json": "{\"weight_map\":{\"old\":\"model-00001-of-00004.safetensors\"}}",
                     "model-00001-of-00002.safetensors": "first",
                     "model-00002-of-00002.safetensors": "second"]
        for (name, contents) in files {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        #expect(CachedModelDownloader.isCompleteModel(at: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(!CachedModelDownloader.isCompleteModel(at: root))
    }

    @Test func incompleteInstallationAttemptsDownloadAndReportsOfflineFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try await cache.storeData(Data("{}".utf8), repo: "test/model", kind: .model,
                                  revision: String(repeating: "b", count: 40),
                                  filename: "config.json", etag: "config", ref: "main")
        let host = UUID().uuidString.lowercased() + ".invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineModelURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let phases = Mutex<[AIModelLoadPhase]>([])
        let downloader = CachedModelDownloader(
            client: HubClient(session: session, host: URL(string: "https://" + host)!, cache: cache),
            phase: { phase in phases.withLock { $0.append(phase) } }
        )
        await #expect(throws: (any Error).self) {
            _ = try await downloader.download(id: "test/model", revision: "main", matching: ["*.json", "*.safetensors"],
                                               useLatest: false, progressHandler: { _ in })
        }
        #expect(OfflineModelURLProtocol.requests.withLock { $0[host, default: 0] } > 0)
        #expect(phases.withLock { $0 } == [.downloading])
    }
}
