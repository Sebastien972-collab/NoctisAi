// Created by Sébastien DAGUIN

import MLXLMCommon
import MLXVLM
#if os(macOS)
import MLXLLM
#endif

enum MLXModelProfile: Equatable, Sendable {
    case bonsai
    case gptOSS
    case standard

    static let gptOSSModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"

    static func resolve(model: ModelContainer) async -> Self {
        await model.perform { context in
            #if os(macOS)
            if context.model is GPTOSSModel { return .gptOSS }
            #endif
            return context.model is PrismHadamardQwen35 ? .bonsai : .standard
        }
    }

    var maximumOutputTokens: Int { self == .gptOSS ? 4_096 : 2_048 }

    var generationParameters: GenerateParameters {
        switch self {
        case .bonsai:
            BonsaiModelConfiguration.generationParameters
        case .gptOSS:
            // Leave room for analysis and a final answer, with a bounded cache on 18 GB Macs.
            GenerateParameters(
                maxTokens: maximumOutputTokens,
                maxKVSize: 12_288,
                temperature: 1,
                topP: 1,
                prefill: .init(stepSize: 256),
                toolCallPolicy: .init(recovery: .disabled, validation: .strict)
            )
        case .standard:
            GenerateParameters(maxTokens: maximumOutputTokens)
        }
    }

    var additionalContext: [String: any Sendable]? {
        switch self {
        case .bonsai: BonsaiModelConfiguration.additionalContext
        case .gptOSS: ["reasoning_effort": "low"]
        case .standard: nil
        }
    }
}
