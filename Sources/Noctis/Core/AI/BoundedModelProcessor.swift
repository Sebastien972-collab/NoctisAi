// Created by Sébastien DAGUIN

import Foundation
import MLXLMCommon

/// Enforces the complete rendered input budget before MLX allocates its generation cache.
struct BoundedModelProcessor: UserInputProcessor {
    let base: any UserInputProcessor
    let maximumInputTokens: Int

    init(base: any UserInputProcessor, maximumInputTokens: Int = 6_144) {
        self.base = base
        self.maximumInputTokens = min(6_144, maximumInputTokens)
    }

    func prepare(input: UserInput) async throws -> LMInput {
        let messages: [Message]
        switch input.prompt {
        case .text(let text): messages = [["role": "user", "content": text]]
        case .messages(let values): messages = values
        case .chat(let values):
            let generator = DefaultMessageGenerator()
            messages = values.map { generator.generate(message: $0) }
        }
        let envelope: [String: Any] = ["messages": messages, "tools": input.tools ?? [],
                                       "context": input.additionalContext ?? [:]]
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).count
        guard bytes <= 262_144 else { throw MLXModelServiceError.contextLimit }
        let prepared = try await base.prepare(input: input)
        try Self.validate(tokens: prepared.text.tokens.size, maximum: maximumInputTokens)
        return prepared
    }

    static func validate(tokens: Int, maximum: Int = 6_144) throws {
        guard maximum > 0, tokens <= maximum else { throw MLXModelServiceError.contextLimit }
    }
}
