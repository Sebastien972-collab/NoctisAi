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


actor MLXModelService: AIModelService {
    private var session: ChatSession?
    private let webToolDispatcher: WebToolDispatcher
    
    init(
        webSearchService: any WebSearchService = SearXNGService()
    ) {
        self.webToolDispatcher = WebToolDispatcher(
            searchService: webSearchService
        )
    }
    
    func load() async throws {
        let model = try await loadModel(
            from: #hubDownloader,
            using: #huggingFaceTokenizerLoader(),
            id: NoctisConfiguration.modelID
        )
        
        let dispatcher = webToolDispatcher
        
        session = ChatSession(
            model,
            instructions: NoctisIdentity.systemPrompt,
            tools: [
                WebSearchTool.schema
            ], toolDispatch: { call in
                try await dispatcher.execute(call)
            }
        )
    }
    
    func generate(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        
        guard let session else {
            throw MLXModelServiceError.modelNotLoaded
        }
        
        return session.streamResponse(to: prompt)
    }
}
