//
//  NoctisCLI.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Noctis

@main
struct NoctisCLI {

    static func main() async {
        let application = NoctisApplication(
            modelService: MLXModelService()
        )

        await application.run()
    }
}
