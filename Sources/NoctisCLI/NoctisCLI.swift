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
                embedded = try EmbeddedSearXNGService.bundled()
            }
        } catch {
            print(error.localizedDescription)
            return
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
