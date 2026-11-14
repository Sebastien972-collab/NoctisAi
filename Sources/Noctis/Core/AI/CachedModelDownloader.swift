// Created by Sébastien DAGUIN

import Foundation
import HuggingFace
import MLXLMCommon

/// Resolve the installed snapshot before allowing any request to the Hub.
struct CachedModelDownloader: Downloader {
    let client: HubClient
    let phase: @Sendable (AIModelLoadPhase) -> Void

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw CocoaError(.fileReadInvalidFileName) }
        let cached: URL?
        do {
            cached = try await client.downloadSnapshot(
                of: repo, revision: revision ?? "main", matching: patterns, localFilesOnly: true
            )
        } catch HubCacheError.cachedPathResolutionFailed {
            cached = nil
        }
        if let cached, Self.isCompleteModel(at: cached) {
            phase(.loading)
            return cached
        }
        try Task.checkCancellation()
        phase(.downloading)
        let directory = try await client.downloadSnapshot(
            of: repo, revision: revision ?? "main", matching: patterns,
            progressHandler: { progressHandler($0) }
        )
        guard Self.isCompleteModel(at: directory) else { throw CocoaError(.fileReadCorruptFile) }
        phase(.loading)
        return directory
    }

    // A local-only Hub lookup can return a partially downloaded snapshot.
    static func isCompleteModel(at directory: URL) -> Bool {
        let files = FileManager.default
        func exists(_ name: String) -> Bool {
            let path = directory.appendingPathComponent(name).path
            return files.isReadableFile(atPath: path)
                && ((try? files.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0) > 0
        }
        guard ["config.json", "tokenizer_config.json", "tokenizer.json"].allSatisfy(exists) else {
            return false
        }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weights = json["weight_map"] as? [String: String], !weights.isEmpty,
           Set(weights.values).allSatisfy(exists) {
            return true
        }
        // Quantized repositories can retain an index from the unquantized model.
        // Accept their conventional shards only when the whole numbered set exists.
        let weights = (try? files.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("model") && $0.hasSuffix(".safetensors") } ?? []
        if weights == ["model.safetensors"] { return exists("model.safetensors") }
        guard let first = weights.first else { return false }
        let parts = first.replacingOccurrences(of: ".safetensors", with: "").split(separator: "-")
        guard parts.count == 4, parts[0] == "model", parts[2] == "of",
              let count = Int(parts[3]), count > 0, count == weights.count else { return false }
        return (1...count).allSatisfy {
            exists(String(format: "model-%05d-of-%05d.safetensors", $0, count))
        }
    }
}
