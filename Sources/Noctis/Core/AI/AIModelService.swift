//
//  AIModelService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


protocol AIModelService {
    func load() async throws

    func generate(
        prompt: String
    ) throws -> AsyncThrowingStream<String, Error>
}
