//
//  NoctisCLI.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Noctis
import Foundation

@main
struct NoctisCLI {

    static func main() async {
        #if os(macOS)
        let embedded: EmbeddedSearXNGService?
        do {
            if let path = ProcessInfo.processInfo.environment["NOCTIS_SEARXNG_PYTHON"] {
                guard path.hasPrefix("/") else { throw EmbeddedSearXNGError.invalidConfiguration }
                embedded = try EmbeddedSearXNGService(pythonExecutable: URL(fileURLWithPath: path))
            } else {
                embedded = try EmbeddedSearXNGService.bundled() ?? EmbeddedSearXNGService.installed()
            }
        } catch {
            print(error.localizedDescription)
            return
        }
        if embedded != nil {
            print("Recherche Web : SearXNG local, démarrage à la demande.")
        } else {
            print("Recherche Web : serveur externe attendu sur 127.0.0.1:8888.")
            print("Pour le mode sans Docker : python3 infrastructure/searxng/setup_runtime.py")
        }
        let modelService = embedded.map { MLXModelService(webSearchService: $0) } ?? MLXModelService()
        #else
        let modelService = MLXModelService()
        #endif
        let application = NoctisApplication(
            modelService: modelService
        )

        await application.run()
        #if os(macOS)
        await embedded?.shutdown()
        #endif
    }
}
