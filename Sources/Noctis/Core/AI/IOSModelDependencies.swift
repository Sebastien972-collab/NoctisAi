// Created by Sébastien DAGUIN
#if os(iOS)
import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

struct IOSModelDependencies: Sendable {
    typealias FoundationClientFactory = @Sendable (
        String, ModelGenerationAccess, (@Sendable () -> String)?
    ) throws -> any NoctisAgentLLMClient

    let availability: @Sendable () -> IOSFoundationModelsAvailability
    let makeMLX: @Sendable () -> MLXModelService
    let makeFoundationModelsClient: FoundationClientFactory

    static func live(
        webSearchService: any WebSearchService,
        presentation: NoctisPresentationInstructions
    ) -> Self {
        Self(
            availability: currentAvailability,
            makeMLX: {
                MLXModelService(webSearchService: webSearchService,
                                modelID: IOSModelConfiguration.mlxModelID, presentation: presentation)
            },
            makeFoundationModelsClient: { prompt, access, instructions in
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    return FoundationModelsLLMClient(
                        systemPrompt: prompt, access: access, instructions: instructions
                    )
                }
                #endif
                throw IOSModelServiceError.foundationModelsUnavailable(currentAvailability())
            }
        )
    }

    static func currentAvailability() -> IOSFoundationModelsAvailability {
        guard #available(iOS 26.0, *) else { return .requiresIOS26 }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        @unknown default:
            return .unknown
        }
        #else
        return .frameworkUnavailable
        #endif
    }
}

final class IOSLoadProgressRelay: Sendable {
    private let lastPhase = OSAllocatedUnfairLock<AIModelLoadPhase?>(initialState: nil)
    private let progress: @Sendable (AIModelLoadPhase) -> Void

    init(_ progress: @escaping @Sendable (AIModelLoadPhase) -> Void) { self.progress = progress }

    func emit(_ phase: AIModelLoadPhase) {
        let changed = lastPhase.withLock {
            guard $0 != phase else { return false }
            $0 = phase
            return true
        }
        if changed { progress(phase) }
    }
}
#endif
