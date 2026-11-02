//
//  MLXModelServiceError.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Foundation
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers


final class MLXModelService: AIModelService {

    private var session: ChatSession?

    func load() async throws {
        let model = try await loadModel(
            from: #hubDownloader,
            using: #huggingFaceTokenizerLoader(),
            id: NoctisConfiguration.modelID
        )

        session = ChatSession(
            model,
            instructions: NoctisIdentity.systemPrompt
        )
    }

    func generate(
        prompt: String
    ) throws -> AsyncThrowingStream<String, Error> {

        guard let session else {
            throw MLXModelServiceError.modelNotLoaded
        }

        return session.streamResponse(to: prompt)
    }
}
