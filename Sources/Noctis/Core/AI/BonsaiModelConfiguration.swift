// Created by Sébastien DAGUIN

import MLXLMCommon

/// PrismML's non-thinking profile keeps the test within Noctis's output budget.
enum BonsaiModelConfiguration {
    static let modelID = "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit"

    static var generationParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: 2_048,
            temperature: 0.7,
            topP: 0.8,
            topK: 20,
            minP: 0,
            repetitionPenalty: 1,
            repetitionContextSize: 64,
            presencePenalty: 1.5,
            presenceContextSize: 64,
            toolCallPolicy: .init(recovery: .disabled, validation: .strict)
        )
    }

    static var additionalContext: [String: any Sendable] {
        ["enable_thinking": false]
    }
}
